-- Repository-evidence tier, part 1 of 3: build the evidence tables.
--
-- Decides Primary vs Secondary by asking the repository who deposited the data and when, then
-- comparing that against the citing article. Highest-precision tier in the pipeline (0.97-1.00
-- on the rdmpage benchmark) and the largest single contributor to the R1 product: 3,308,263
-- decisions, 38.1% of all classifications.
--
-- Ported 2026-09-03 from the original R1 queries, recovered from BigQuery job history and kept
-- verbatim in r1-recovered-sql/ (jobs of 2026-08-13/14). Read that directory's README before
-- changing anything here; the numeric thresholds and guards below are not arbitrary.
--
-- Two independent paths, because the evidence sources differ:
--   * gen family, non-SRA accessions -> insdc_provenance, the 287.7M-row GenBank lake
--     (96.8% of repo decisions)
--   * biosample / bioproject / metagenomics, plus SRA-style gen accessions
--     -> repo_metadata (API-fetched) + sra_bq_metadata (public SRA mirror)
--
-- Cheap relative to the sweep: both paths join on accession, and all three provenance tables
-- are clustered by accession.

-- Non-gen path, step 1: base evidence from the API/SRA metadata.
CREATE OR REPLACE TABLE `${work_dataset}.repo_evidence`
CLUSTER BY family, accession AS
WITH meta AS (
  -- One row per accession. Longest submitter string wins (the fetchers sometimes return a
  -- truncated author list for the same accession from different sources).
  SELECT UPPER(accession) acc,
         ANY_VALUE(submitters HAVING MAX LENGTH(submitters)) submitters,
         MAX(REGEXP_EXTRACT(deposit_date, r'(\d{4})')) dep_year_api,
         MAX(NULLIF(linked_pubmed,'')) linked_pubmed, MAX(NULLIF(linked_doi,'')) linked_doi,
         LOGICAL_OR(found) found
  FROM `${work_dataset}.repo_metadata` GROUP BY 1
),
sra AS (
  SELECT UPPER(accession) acc, center_name, EXTRACT(YEAR FROM first_release) rel_year, bioproject
  FROM `${work_dataset}.sra_bq_metadata`
),
pairs AS (
  -- Author surnames only, >= 4 chars: short surnames produce false substring hits against
  -- submitter strings (the overlap test below is STRPOS, not equality).
  SELECT t.publication_id, t.accession, t.family, t.type, t.rule_applied,
         p.pmid, LOWER(p.doi) pub_doi, p.year pub_year,
         ARRAY(SELECT LOWER(au.last_name) FROM UNNEST(p.authors) au
               WHERE au.last_name IS NOT NULL AND LENGTH(au.last_name) >= 4) au_names
  FROM `${work_dataset}.accession_citations_typed` t
  JOIN `${publications_metadata}` p ON p.id = t.publication_id
  -- pdb and geo added 2026-09-03: their metadata now arrives via api_fetch_shard (RCSB GraphQL
  -- and NCBI GEO esummary respectively), and between them they were 249,679 of the residue's
  -- citations -- the largest block with no evidence-tier coverage.
  WHERE t.family IN ('biosample','bioproject','metagenomics','pdb','geo')
     OR (t.family = 'gen' AND REGEXP_CONTAINS(t.accession, r'^[SED]R[APRSXZ]\d{6,}$'))
)
SELECT pr.*, m.submitters, m.linked_pubmed, m.linked_doi,
       COALESCE(CAST(m.dep_year_api AS INT64), s.rel_year) dep_year,
       s.bioproject sra_bioproject, s.center_name,
       IFNULL(m.found, s.acc IS NOT NULL) found,
       (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
         WHERE STRPOS(LOWER(IFNULL(m.submitters,'')), n) > 0) submitter_overlap,
       CASE
         -- The repository record points at THIS article -> the article is the data's source.
         -- The delimiter-anchored STRPOS handles sources that return several linked PMIDs for
         -- one accession (GEO does; a GSE often cites both the original paper and a later
         -- reanalysis). Anchoring on ';' prevents '123' matching '1234'.
         WHEN m.linked_pubmed IS NOT NULL AND (m.linked_pubmed = pr.pmid
              OR STRPOS(CONCAT(';', m.linked_pubmed, ';'), CONCAT(';', pr.pmid, ';')) > 0)
              THEN 'linked_pub_primary'
         WHEN m.linked_doi IS NOT NULL AND LOWER(m.linked_doi) = pr.pub_doi THEN 'linked_pub_primary'
         -- Points at a DIFFERENT article -> reuse. The `= 0` overlap requirement is the
         -- preprint-trap guard: without it, a record linked to the same team's preprint gets
         -- misread as third-party reuse (2 of the 123 adjudicated cases failed exactly that way).
         -- The submitters-present condition is what keeps that guard MEANINGFUL: for a source
         -- with no submitter names (GEO esummary exposes none) the overlap is trivially 0, so
         -- without this the guard would pass vacuously and every linked-elsewhere GEO record
         -- would be called reuse. Verified a no-op for the existing families: zero rows in
         -- repo_metadata have a linked PMID and no submitters.
         WHEN (m.linked_pubmed IS NOT NULL OR m.linked_doi IS NOT NULL)
              AND m.submitters IS NOT NULL AND m.submitters != ''
              AND (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
                   WHERE STRPOS(LOWER(IFNULL(m.submitters,'')), n) > 0) = 0 THEN 'linked_other_secondary'
         -- Same people, same time -> the article's own deposit.
         WHEN (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
               WHERE STRPOS(LOWER(IFNULL(m.submitters,'')), n) > 0) >= 1
              AND COALESCE(CAST(m.dep_year_api AS INT64), s.rel_year) IS NOT NULL
              AND ABS(COALESCE(CAST(m.dep_year_api AS INT64), s.rel_year) - pr.pub_year) <= 1
              THEN 'author_date_primary'
         -- Deposited more than a year before publication -> this article cannot be the origin.
         WHEN COALESCE(CAST(m.dep_year_api AS INT64), s.rel_year) < pr.pub_year - 1
              THEN 'deposit_precedes_secondary'
         ELSE 'undecided'
       END decision
FROM pairs pr
LEFT JOIN meta m ON m.acc = UPPER(pr.accession)
LEFT JOIN sra s ON s.acc = UPPER(pr.accession);

-- Non-gen path, step 2: two rules that need more than the accession's own metadata.
CREATE OR REPLACE TABLE `${work_dataset}.repo_evidence2`
CLUSTER BY family, accession AS
WITH ev AS (SELECT * FROM `${work_dataset}.repo_evidence`),
affil AS (
  SELECT p.id publication_id,
         LOWER((SELECT STRING_AGG(aff, ' ') FROM UNNEST(p.authors) au, UNNEST(au.raw_affiliations) aff)) affils
  FROM `${publications_metadata}` p
  WHERE p.id IN (SELECT DISTINCT publication_id FROM ev)
),
org_sig AS (
  -- Submitters here are ORGANISATIONS, not people, so the surname overlap above never fires;
  -- match distinctive org tokens against author affiliations instead. The stopword list removes
  -- the words that would otherwise match almost any academic affiliation, and the >= 6 length
  -- floor removes the rest of the noise.
  SELECT ev.publication_id, ev.accession,
    (SELECT COUNT(*) FROM UNNEST(SPLIT(REGEXP_REPLACE(LOWER(IFNULL(ev.center_name, ev.submitters)), r'[^a-z ]', ' '), ' ')) tok
      WHERE LENGTH(tok) >= 6 AND tok NOT IN ('university','institute','national','center','centre','research',
        'laboratory','college','department','hospital','sciences','science','institut','institution','academy')
        AND STRPOS(IFNULL(a.affils,''), tok) > 0) org_hits
  FROM ev JOIN affil a USING (publication_id)
),
primaries AS (
  -- Cross-family consistency: which BioProjects are already Primary for this article?
  SELECT DISTINCT e.publication_id, e.sra_bioproject
  FROM ev e JOIN `${work_dataset}.accession_citations_typed` t
    ON t.publication_id = e.publication_id AND t.accession = e.accession
  WHERE t.type = 'Primary' AND e.sra_bioproject IS NOT NULL
)
SELECT ev.*, IFNULL(o.org_hits, 0) org_hits,
  CASE
    WHEN ev.decision != 'undecided' THEN ev.decision
    -- A BioProject whose samples are Primary for this article is itself Primary.
    WHEN ev.family = 'bioproject' AND pr.sra_bioproject IS NOT NULL THEN 'project_of_primary'
    WHEN IFNULL(o.org_hits,0) >= 1 AND ev.dep_year IS NOT NULL
         AND ABS(ev.dep_year - ev.pub_year) <= 1 THEN 'org_date_primary'
    ELSE 'undecided'
  END decision2
FROM ev
LEFT JOIN org_sig o ON o.publication_id = ev.publication_id AND o.accession = ev.accession
LEFT JOIN primaries pr ON pr.publication_id = ev.publication_id AND pr.sra_bioproject = ev.accession;

-- Gen path: the same inferences against the INSDC provenance lake, which carries submitter
-- authors (real names) rather than centre names -- so surname overlap works here and the
-- org-token rule is unnecessary.
--
-- Two attribution sources, one cascade. insdc_provenance is the GenBank lake (bulk release plus
-- daily appends, frozen once the daily mirror retires). insdc_attribution is the targeted
-- E-utilities cache of cited accessions only, parsed with the lake's own parser, so its rows are
-- field-for-field the same shape (DESIGN-targeted-insdc-fetch.md). The lake stays in the union
-- as a fallback: a record withdrawn at NCBI returns nothing from the API but survives here.
-- Both gates are FALSE unless set on the stage-runner function; with them FALSE the cache
-- contributes no rows and every decision is exactly what the lake alone produced.
CREATE TABLE IF NOT EXISTS `${work_dataset}.insdc_attribution` (
  accession STRING, record_accession STRING, db STRING, found BOOL, submit_date STRING,
  submit_authors STRING, submit_affiliation STRING, pubmed_ids STRING, fetched_at TIMESTAMP,
  ref_authors STRING);
ALTER TABLE `${work_dataset}.insdc_attribution` ADD COLUMN IF NOT EXISTS ref_authors STRING;

-- Name normaliser for the surname+initial match below: strips diacritics (Pérez = Perez, Ágoston =
-- Agoston) and every non-letter, lowercased.
CREATE TEMP FUNCTION _norm(s STRING) AS (
  REGEXP_REPLACE(REGEXP_REPLACE(NORMALIZE(LOWER(IFNULL(s, '')), NFD), r'\p{M}', ''), r'[^a-z]', ''));

CREATE OR REPLACE TABLE `${work_dataset}.gen_evidence`
CLUSTER BY accession AS
WITH lake_rows AS (
  SELECT accession, submit_authors, submit_date, pubmed_ids,
         CAST(NULL AS STRING) ref_authors, FALSE is_protein
  FROM `${work_dataset}.insdc_provenance`
  UNION ALL
  SELECT accession, submit_authors, submit_date, pubmed_ids, ref_authors, db = 'protein'
  FROM `${work_dataset}.insdc_attribution`
  WHERE ${insdc_attribution_enabled} AND found
    AND (db = 'nuccore' OR ${insdc_include_protein})
),
lake AS (
  SELECT UPPER(accession) acc,
         ANY_VALUE(submit_authors HAVING MAX LENGTH(submit_authors)) submit_authors,
         MAX(REGEXP_EXTRACT(submit_date, r'(\d{4})')) dep_year,
         STRING_AGG(DISTINCT pubmed_ids, '|') pubmeds,
         ANY_VALUE(ref_authors HAVING MAX LENGTH(ref_authors)) ref_authors,
         LOGICAL_OR(is_protein) is_protein
  FROM lake_rows GROUP BY 1
),
pairs AS (
  SELECT t.publication_id, t.accession, t.type, t.rule_applied,
         p.pmid, p.year pub_year,
         ARRAY(SELECT LOWER(au.last_name) FROM UNNEST(p.authors) au
               WHERE au.last_name IS NOT NULL AND LENGTH(au.last_name) >= 4) au_names,
         ARRAY(SELECT AS STRUCT _norm(au.last_name) ln, SUBSTR(_norm(au.first_name), 1, 1) fi
               FROM UNNEST(p.authors) au
               WHERE au.last_name IS NOT NULL AND au.first_name IS NOT NULL) au_ini
  FROM `${work_dataset}.accession_citations_typed` t
  JOIN `${publications_metadata}` p ON p.id = t.publication_id
  WHERE t.family = 'gen' AND t.type != 'Excluded'
    -- SRA-style accessions are covered by repo_evidence above, not the lake.
    AND NOT REGEXP_CONTAINS(t.accession, r'^[SED]R[APRSXZ]\d{6,}$')
    -- Skip pairs a repo rule already decided, so re-running is cheap and idempotent.
    AND t.rule_applied NOT LIKE 'repo_%'
),
-- Where, and how, each pair's accession is mentioned in the article (for non_data_context below).
ctx AS (
  SELECT publication_id, UPPER(accession) acc,
         LOGICAL_AND(REGEXP_CONTAINS(location, r'^(acknowledgement|funding)_')) all_ack,
         LOGICAL_AND(location IN ('body_sentences', 'body_titles')) all_body,
         LOGICAL_OR(REGEXP_CONTAINS(location, r'^(tables|graphics)')) has_table,
         LOGICAL_OR(REGEXP_CONTAINS(IFNULL(sentence, ''),
           r'(?i)genbank|accession|\bESTs?\b|mRNA|cDNA|clone|sequenc|deposit|NCBI|INSDC|\bENA\b|DDBJ')) cue
  FROM `${work_dataset}.accession_contexts` GROUP BY 1, 2
)
SELECT pr.publication_id, pr.accession,
  CASE
    -- Distinguished from 'undecided': the accession is absent from the lake (a suppressed or
    -- post-release record), which is information, not an inconclusive comparison.
    WHEN l.acc IS NULL THEN 'no_metadata_yet'
    -- Exact membership, not STRPOS: a bare substring test lets PMID 12345 match inside 9123456.
    -- Measured 2026-09-25 as latent -- 583,625 matches either way, 0 citations decided wrongly --
    -- but the insdc_attribution cache adds PubMed links, so it would not have stayed latent.
    -- pubmeds is '|'-joined at every level (lake rows, the cache, and the STRING_AGG above).
    WHEN pr.pmid IS NOT NULL AND pr.pmid IN UNNEST(SPLIT(IFNULL(l.pubmeds,''), '|'))
         THEN 'linked_pub_primary'
    -- Protein companion-paper guard (Simon, 2026-09-25). Protein records from genome projects
    -- carry a sequencing centre as Direct Submission author and the genome paper's consortium
    -- (median 37-64 names) in their other references. A citing article sharing an author with
    -- that consortium AND published within a year of the deposit is plausibly a companion paper
    -- of the project that produced the protein, so it is HELD rather than called reuse. Older
    -- deposits are left to linked_other_secondary: reusing your own earlier deposit is still
    -- reuse. Sized on the shadow diff: 492 of 162,632 protein linked_other_secondary pairs.
    -- Stage 67 must exclude this decision, or it would be written back as Secondary.
    WHEN l.is_protein AND l.pubmeds IS NOT NULL AND l.pubmeds != ''
         AND (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
              WHERE STRPOS(LOWER(IFNULL(l.submit_authors,'')), n) > 0) = 0
         AND (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
              WHERE STRPOS(LOWER(IFNULL(l.ref_authors,'')), n) > 0) >= 1
         AND SAFE_CAST(l.dep_year AS INT64) IS NOT NULL
         AND ABS(SAFE_CAST(l.dep_year AS INT64) - pr.pub_year) <= 1 THEN 'held_protein_companion'
    WHEN l.pubmeds IS NOT NULL AND l.pubmeds != ''
         AND (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
              WHERE STRPOS(LOWER(IFNULL(l.submit_authors,'')), n) > 0) = 0 THEN 'linked_other_secondary'
    WHEN (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
          WHERE STRPOS(LOWER(IFNULL(l.submit_authors,'')), n) > 0) >= 1
         AND SAFE_CAST(l.dep_year AS INT64) IS NOT NULL
         AND ABS(SAFE_CAST(l.dep_year AS INT64) - pr.pub_year) <= 1 THEN 'author_date_primary'
    WHEN SAFE_CAST(l.dep_year AS INT64) < pr.pub_year - 1 THEN 'deposit_precedes_secondary'
    -- author_initial_date_primary (added 2026-10-16). The surname-only rule above ignores surnames
    -- under 4 letters (Li, Wu, Xu, Lu, Liu, Sun, Han ...), which are the commonest surnames in
    -- the submitters of newly deposited sequences, and does not fold diacritics. Here a citing
    -- author matches a submitter on normalised surname AND first initial, and TWO distinct
    -- authors must match. One shared 'Li,X.' is far too weak; two is the paper's own group.
    -- Measured against the labelled decisions (deposit within a year of publication, new
    -- matches only): 8,076 linked_pub_primary vs 245 linked_other_secondary = 97.1% precision
    -- proxy; a single first/last-author match was 95.6% and a single middle-author match
    -- 82.2%, so neither ships. Only reached by pairs the rules above left 'undecided'.
    WHEN SAFE_CAST(l.dep_year AS INT64) IS NOT NULL
         AND ABS(SAFE_CAST(l.dep_year AS INT64) - pr.pub_year) <= 1
         AND (SELECT COUNT(DISTINCT CONCAT(a.ln, '|', a.fi)) FROM UNNEST(pr.au_ini) a
              WHERE a.fi != '' AND LENGTH(a.ln) >= 2
                AND EXISTS (SELECT 1 FROM UNNEST(SPLIT(
                              REGEXP_REPLACE(IFNULL(l.submit_authors, ''), r'\.,\s*|\s+and\s+', '|'), '|')) x
                            WHERE _norm(SPLIT(x, ',')[SAFE_OFFSET(0)]) = a.ln
                              AND SUBSTR(_norm(SPLIT(x, ',')[SAFE_OFFSET(1)]), 1, 1) = a.fi)) >= 2
         THEN 'author_initial_date_primary'
    -- non_data_context (added 2026-10-17). The accession is a real record in the lake but carries
    -- no submitter data (mostly EST/GSS), so nothing above could decide it -- and about half of
    -- these candidates are not sequence citations at all: grant numbers (CA077263), catalogue
    -- and lot numbers (C74986), ethics approvals (R18017), isolate and sample ids (H27846) that
    -- happen to have an old EST accession's shape. Two shapes carry nearly all of the noise:
    -- one letter + five digits, and two letters + six digits (the NIH grant-prefix collision).
    -- Excluded only when EVERY mention is in funding/acknowledgements (either shape) or in the
    -- article body (one-letter shape only), none is in a table or figure, and no mention
    -- sentence contains a sequence cue word. Applies to pairs still 'residual' here (stage 69 only labels rows still
    -- Unclassified, so its ~52k model_secondary pairs are residual at this point in a monthly run)
    -- and to the cue rules' pairs (cue_secondary, cue_primary, cue_primary_not_first). Each
    -- population was sampled separately on 2026-10-17: residual 90/90, model_secondary 85/86,
    -- cue_secondary 34/35, cue_primary(+_not_first) 58/58 non-data. The 58 cue_primary pairs were
    -- Primary claims on grant and reagent numbers; this removes them. model_primary is not
    -- covered (11 pairs, none in the rule's shapes). Judged by Claude, not hand-labelled; lower
    -- confidence bound about 0.94 on the weakest population. Samples: review/genbank_noise_rule_sample_20261017.csv.
    -- Mentions inside tables and
    -- the two-letter shape's body mentions are NOT excluded (about 88% and 64% real EST /
    -- accession lists respectively): they stay Unclassified. Only reached by pairs the rules
    -- above left 'undecided'. Stage 67 writes this decision back as Excluded.
    WHEN pr.rule_applied IN ('residual', 'cue_secondary', 'cue_primary', 'cue_primary_not_first', 'model_secondary')
         AND IFNULL(l.submit_authors, '') = '' AND c.acc IS NOT NULL
         AND NOT c.has_table AND NOT c.cue
         AND ((REGEXP_CONTAINS(UPPER(pr.accession), r'^[A-Z][0-9]{5}$') AND (c.all_ack OR c.all_body))
              OR (REGEXP_CONTAINS(UPPER(pr.accession), r'^[A-Z]{2}[0-9]{6}$') AND c.all_ack))
         THEN 'non_data_context'
    ELSE 'undecided'
  END decision
FROM pairs pr LEFT JOIN lake l ON l.acc = UPPER(pr.accession)
LEFT JOIN ctx c ON c.publication_id = pr.publication_id AND c.acc = UPPER(pr.accession);

-- Cellosaurus path (added 2026-10-16). Source evidence for Primary on cell-line citations.
--
-- Cellosaurus lists, per cell line, the publications that describe it. A citing paper is called
-- Primary only when the line's own record shows it is the FIRST description of the line:
--   * the paper is in the line's reference list (matched on PubMed id or DOI), and
--   * its publication year is strictly earlier than every other reference of that line, and
--   * every reference of the line has a year (patents, datasheets and DOI-only references are
--     loaded without one, so a line that has any cannot be shown to have a first paper), and
--   * the paper is not an antibody-validation study. Those use commercially sourced knockout
--     lines that Cellosaurus registers from the study, which did not derive them.
-- Everything else in the list is `in_refs_not_first` and stays Secondary. Never inferred from
-- a title or from the mention text: a paper that merely uses HeLa and appears in HeLa's 80+
-- references is not its originator. Requires `cellosaurus_refs` (scripts/load_cellosaurus.py).
CREATE OR REPLACE TABLE `${work_dataset}.cellosaurus_evidence`
CLUSTER BY accession AS
WITH r0 AS (
  SELECT UPPER(accession) acc, pmid, LOWER(doi) doi, ref_year,
         COUNTIF(ref_year IS NULL) OVER (PARTITION BY accession) n_undated,
         MIN(ref_year) OVER (PARTITION BY accession) min_year
  FROM `${work_dataset}.cellosaurus_refs`),
refs AS (
  SELECT *, COUNTIF(ref_year = min_year) OVER (PARTITION BY acc) n_at_min_year FROM r0),
pairs AS (
  SELECT DISTINCT t.publication_id, t.accession, CAST(p.pmid AS STRING) pmid, LOWER(p.doi) doi,
         REGEXP_CONTAINS(LOWER(IFNULL(p.title.preferred, '')), r'antibod') AS is_antibody_study
  FROM `${work_dataset}.accession_citations_typed` t
  JOIN `${publications_metadata}` p ON p.id = t.publication_id
  WHERE t.family = 'cellosaurus' AND t.type != 'Excluded')
SELECT pr.publication_id, pr.accession,
       CASE WHEN LOGICAL_OR(r.ref_year = r.min_year AND r.n_at_min_year = 1 AND r.n_undated = 0)
                 AND NOT LOGICAL_OR(pr.is_antibody_study)
            THEN 'first_ref_primary' ELSE 'in_refs_not_first' END AS decision,
       MIN(r.ref_year) AS matched_ref_year, MAX(r.min_year) AS line_first_year
FROM pairs pr
JOIN refs r ON r.acc = UPPER(pr.accession)
 AND ((pr.pmid IS NOT NULL AND pr.pmid = r.pmid) OR (pr.doi IS NOT NULL AND pr.doi = r.doi))
GROUP BY 1, 2;
