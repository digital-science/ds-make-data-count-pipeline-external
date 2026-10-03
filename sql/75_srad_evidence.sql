-- SRAD evidence: the inputs each tier actually consumed, one table per tier.
-- A researcher reads `srad.citations.tier` and joins the ONE table it names.
--
-- Why not a single wide table: it would be mostly NULL and would obscure which tier decided.
-- Why not a long (attribute, value) table: every question would become a pivot.

-- ---------------------------------------------------------------------------------------------
-- DOI arm: metadata similarity.
-- The creator and author name ARRAYS are the point of this table. A researcher who sees
-- author_overlap_frac = 0 needs to see WHY -- the same people in different formats, an
-- organisational depositor, or a genuinely different group. Without the names that is
-- unfalsifiable, and it is exactly where this project's worst near-miss lived: a name-matching
-- fix measured 0.795 precision and had to be narrowed to a complete-match condition.
-- Both the exact and the token-matched overlap counts are exposed, because the rules use the
-- exact one for three of their four arms and the token-matched one only at frac = 1.0.
CREATE OR REPLACE TABLE `${srad_dataset}.evidence_metadata`
PARTITION BY release_date
CLUSTER BY publication_id AS
WITH rel AS (SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
                    DATE_TRUNC(CURRENT_DATE(), MONTH) AS release_date)
SELECT
  rel.release, rel.release_date,
  t.publication_id,
  t.dataset_doi AS dataset_id,
  t.author_overlap_exact,
  t.author_overlap_cnt      AS author_overlap_tokenised,
  t.author_overlap_frac_exact,
  t.author_overlap_frac     AS author_overlap_frac_tokenised,
  t.n_ds_creators,
  t.ds_creator_names,
  t.pub_author_lastnames,
  t.title_jaccard,
  t.ds_title,
  t.pub_title,
  t.is_supplement_to_article,
  t.n_citing_articles,
  t.citing_rank,
  t.ds_year,
  t.pub_year,
  t.year_gap,
  t.client_id AS datacite_client,
  t.resource_type
FROM `${work_dataset}.doi_citations_typed` t
CROSS JOIN rel;


-- ---------------------------------------------------------------------------------------------
-- Accession arm: repository deposit evidence.
-- `decision` carries the cascade outcome verbatim, INCLUDING no_metadata_yet and undecided --
-- the states that say "we held no evidence". A researcher needs those explicitly, or absence of
-- evidence reads as evidence of reuse.
--
-- The gen family is unioned in from gen_evidence joined to the provenance lake, because
-- gen_evidence stores only a decision without its inputs. Without this join the largest family
-- (4.1M pairs) would be the least traceable thing in the dataset.
CREATE OR REPLACE TABLE `${srad_dataset}.evidence_repository`
PARTITION BY release_date
CLUSTER BY publication_id, family AS
WITH rel AS (SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
                    DATE_TRUNC(CURRENT_DATE(), MONTH) AS release_date),
-- The SAME attribution sources as stage 66, behind the same gates, so the trace shows exactly
-- the evidence that decided each pair. Reading only insdc_provenance here left every pair
-- decided from the targeted cache showing record_found = FALSE beside a decision such as
-- linked_pub_primary (303,796 rows in release 202609, fixed the same day).
lake_rows AS (
  SELECT accession, submit_authors, submit_date, pubmed_ids, submit_affiliation,
         CAST(NULL AS STRING) AS ref_authors, 'insdc_provenance' AS src
  FROM `${work_dataset}.insdc_provenance`
  UNION ALL
  SELECT accession, submit_authors, submit_date, pubmed_ids, submit_affiliation,
         ref_authors, 'insdc_attribution' AS src
  FROM `${work_dataset}.insdc_attribution`
  WHERE ${insdc_attribution_enabled} AND found
    AND (db = 'nuccore' OR ${insdc_include_protein})
),
lake AS (
  SELECT UPPER(accession) AS acc,
         ANY_VALUE(submit_authors HAVING MAX LENGTH(submit_authors)) AS submitters,
         MAX(REGEXP_EXTRACT(submit_date, r'(\d{4})')) AS dep_year,
         STRING_AGG(DISTINCT pubmed_ids, '|') AS linked_pubmed,
         ANY_VALUE(submit_affiliation HAVING MAX LENGTH(submit_affiliation)) AS submit_affiliation,
         ANY_VALUE(ref_authors HAVING MAX LENGTH(ref_authors)) AS reference_authors,
         -- which source(s) the evidence came from, e.g. 'insdc_attribution' or both
         STRING_AGG(DISTINCT src, ' + ' ORDER BY src) AS evidence_table
  FROM lake_rows
  GROUP BY 1
),
non_gen AS (
  SELECT publication_id, accession AS dataset_id, family,
         submitters, CAST(linked_pubmed AS STRING) AS linked_pubmed, linked_doi,
         CAST(dep_year AS STRING) AS dep_year, submitter_overlap, center_name,
         found AS record_found, decision,
         CAST(NULL AS STRING) AS submit_affiliation,
         CAST(NULL AS STRING) AS reference_authors,
         'repo_metadata / sra_bq_metadata' AS evidence_table
  FROM `${work_dataset}.repo_evidence`
),
gen AS (
  SELECT g.publication_id, g.accession AS dataset_id, 'gen' AS family,
         l.submitters, l.linked_pubmed, CAST(NULL AS STRING) AS linked_doi,
         l.dep_year, CAST(NULL AS INT64) AS submitter_overlap,
         CAST(NULL AS STRING) AS center_name,
         (l.acc IS NOT NULL) AS record_found, g.decision,
         l.submit_affiliation,
         -- all reference-block authors: what the protein companion-paper guard reasons from
         l.reference_authors,
         IFNULL(l.evidence_table, 'none') AS evidence_table
  FROM `${work_dataset}.gen_evidence` g
  LEFT JOIN lake l ON l.acc = UPPER(g.accession)
)
SELECT rel.release, rel.release_date, e.*
FROM (SELECT * FROM non_gen UNION ALL SELECT * FROM gen) e
CROSS JOIN rel;


-- ---------------------------------------------------------------------------------------------
-- Accession arm: mention-context cues. `cues_matched` joins srad.cue_lexicon, so "which words
-- drove this" is answerable rather than just "the score was 1.8".
CREATE OR REPLACE TABLE `${srad_dataset}.evidence_cues`
PARTITION BY release_date
CLUSTER BY publication_id AS
WITH rel AS (SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
                    DATE_TRUNC(CURRENT_DATE(), MONTH) AS release_date)
SELECT rel.release, rel.release_date,
       c.publication_id, c.accession AS dataset_id, c.family,
       c.score AS cue_score, c.n_mentions, c.all_cues AS cues_matched, c.cue_type
FROM `${work_dataset}.accession_cue_scores` c
CROSS JOIN rel;


-- ---------------------------------------------------------------------------------------------
-- Accession arm: model tier. The feature vector is carried alongside the probability so a
-- researcher can re-run ML.PREDICT against srad.methods.mdc_type_clf_v1 and reproduce the
-- number, rather than taking it on trust.
CREATE OR REPLACE TABLE `${srad_dataset}.evidence_model`
PARTITION BY release_date
CLUSTER BY publication_id AS
WITH rel AS (SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
                    DATE_TRUNC(CURRENT_DATE(), MONTH) AS release_date)
SELECT rel.release, rel.release_date,
       s.publication_id, s.accession AS dataset_id, s.family,
       s.p_primary,
       'mdc_type_clf_v1' AS method_id,
       0.85 AS threshold_primary,
       0.10 AS threshold_secondary,
       f.* EXCEPT (publication_id, accession, family)
FROM `${work_dataset}.model_scores` s
LEFT JOIN `${work_dataset}.model_features` f
  USING (publication_id, accession, family)
CROSS JOIN rel;


-- ---------------------------------------------------------------------------------------------
-- DOI arm: LLM tier. The sentence is NOT duplicated here -- it comes from srad.mentions and
-- inherits the open-access gate, so there is exactly one path to sentence text.
--
-- method_id is asserted from the generating script, not recorded at inference time: the cached
-- verdict table carries no model identifier, because the endpoint lived in the SQL rather than
-- in the data. New verdicts should write it at generation. Labelled here so the distinction
-- between "recorded" and "asserted" is visible in the data itself.
--
-- `scored_mention_ordinal` points at the EXACT mention the model read. This is not cosmetic: the
-- method scores one representative sentence per pair, chosen by its own preference order, and
-- that order is not identical to srad.mentions.mention_ordinal (mentions ranks
-- availability_titles separately). So joining mention_ordinal = 1 would usually but not always
-- return the sentence actually scored -- "usually" being useless for reproducing a decision. The
-- ordinal is resolved by matching the stored sentence text against the ungated mention source,
-- which pins it exactly without creating a second path to sentence text.
CREATE OR REPLACE TABLE `${srad_dataset}.evidence_llm`
PARTITION BY release_date
CLUSTER BY publication_id AS
WITH rel AS (SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
                    DATE_TRUNC(CURRENT_DATE(), MONTH) AS release_date)
, ord_all AS (
  -- Same ordinal definition as srad.mentions, computed over the ungated source so the scored
  -- sentence can be located by text without exposing text here.
  SELECT publication_id, doi AS dataset_id, location, text,
         ROW_NUMBER() OVER (
           PARTITION BY publication_id, doi
           ORDER BY CASE location
                      WHEN 'availability_sentences' THEN 1
                      WHEN 'availability_titles'    THEN 2
                      WHEN 'abstract_sentences'     THEN 3
                      WHEN 'body_sentences'         THEN 4
                      ELSE 5 END,
                    LENGTH(IFNULL(text, '')) DESC,
                    location) AS mention_ordinal
  FROM `${work_dataset}.datacite_sentence_matches_confirmed_remapped`
),
ord AS (
  -- DEDUP GUARD. The join below is on sentence TEXT, and identical text can occur at more than
  -- one location for the same pair, so an unguarded join fans out: measured 68,878 source rows
  -- becoming 69,760 (882 duplicates) before this was added. Collapsing to the lowest ordinal per
  -- (pair, text) is also the right answer, not merely a deduplication -- the lowest ordinal is
  -- the occurrence the method's own preference order would have selected.
  SELECT publication_id, dataset_id, text, MIN(mention_ordinal) AS mention_ordinal
  FROM ord_all GROUP BY 1, 2, 3
)
SELECT rel.release, rel.release_date,
       l.publication_id,
       l.dataset_doi AS dataset_id,
       UPPER(REGEXP_EXTRACT(l.llm_raw, r'(?i)(PRIMARY|SECONDARY|NOT_DATA|UNCLEAR)')) AS verdict,
       l.llm_raw AS raw_response,
       l.cell AS stratum,
       l.sentence_location,
       o.mention_ordinal AS scored_mention_ordinal,
       'llm_doi_primary_v3' AS method_id,
       'asserted_from_generating_script' AS method_id_provenance,
       (UPPER(REGEXP_EXTRACT(l.llm_raw, r'(?i)(PRIMARY|SECONDARY|NOT_DATA|UNCLEAR)')) = 'PRIMARY')
         AS verdict_was_applied
FROM `${work_dataset}.llm_doi_primary_scores` l
LEFT JOIN ord o
  ON o.publication_id = l.publication_id
 AND o.dataset_id = l.dataset_doi
 AND o.text = l.sentence
CROSS JOIN rel;
