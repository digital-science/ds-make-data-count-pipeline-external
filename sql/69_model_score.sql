-- Model tier: score the residue with the calibrated classifier and write only confident calls.
--
-- Runs after the repository-evidence tier (66-68) and before the product view (70), so it sees
-- the residue those rules could not decide. 930,959 decisions in R1 (10.7% of the product):
-- model_secondary 926,393 and model_primary 4,566 -- overwhelmingly a Secondary detector.
--
-- Ported 2026-09-03 from R1's queries recovered from BigQuery job history (jobs 2026-08-14
-- 12:31 / 13:23), kept verbatim in r1-recovered-sql/022 and the model_queries set. Training is
-- deliberately NOT part of this stage -- see sql/manual/train_type_clf_v1.sql for why.
--
-- Two deviations from R1, both deliberate:
--   * `verified_in_text` is computed here instead of being ALTERed onto
--     accession_citations_typed and back-filled (R1 did that on 2026-08-12). It is purely
--     derived -- "does this pair appear in accession_contexts" -- so deriving it cannot go
--     stale, and it avoids re-running 62-68 to add a column only this stage reads.
--   * The model is referenced through ${type_model} rather than hardcoded, so the artifact can
--     live outside work_dataset (in R1 it sits in the product dataset).

CREATE OR REPLACE TABLE `${work_dataset}.model_features`
CLUSTER BY split, family AS
WITH ctx AS (
  SELECT publication_id, accession,
    COUNT(*) n_mentions,
    COUNT(DISTINCT location) n_locations,
    LOGICAL_OR(location LIKE 'availability%') in_availability,
    LOGICAL_OR(location LIKE 'body%')         in_body,
    LOGICAL_OR(location LIKE 'abstract%')     in_abstract,
    LOGICAL_OR(location = 'tables_rows')      in_table_rows,
    LOGICAL_OR(location LIKE 'references%')   in_references,
    AVG(LENGTH(sentence)) avg_sentence_len,
    -- share of mentions that are a bare identifier with no surrounding prose: a citation with
    -- no sentence context around it behaves very differently from one in a real sentence.
    AVG(CAST(LENGTH(REGEXP_REPLACE(sentence, r'[A-Za-z]+\d[\w.\-]*|[\s|.,;:()\[\]]+', '')) < 10 AS INT64)) bare_id_share
  FROM `${work_dataset}.accession_contexts` GROUP BY 1, 2
),
cue AS (
  SELECT publication_id, accession, ANY_VALUE(score) cue_score, ANY_VALUE(n_mentions) cue_n,
         ANY_VALUE(all_cues) all_cues
  FROM `${work_dataset}.accession_cue_scores` GROUP BY 1, 2
),
art AS (
  SELECT p.id publication_id, p.year pub_year, ARRAY_LENGTH(p.authors) n_authors,
    IFNULL(p.journal.title, '') journal,
    REGEXP_CONTAINS(LOWER(IFNULL(p.title.preferred,'')),
      r'genome (sequence|assembly)|data descriptor|^a dataset|complete genome|draft genome') title_data_paper,
    LOWER(IFNULL(p.journal.title,'')) IN ('scientific data','gigascience','data in brief',
      'wellcome open research','micropublication biology','biodiversity data journal',
      'f1000research','genome announcements','microbiology resource announcements') journal_data_venue
  FROM `${publications_metadata}` p
),
sib AS (
  SELECT publication_id,
    COUNT(*) n_accession_pairs_in_article,
    COUNT(DISTINCT family) n_families_in_article
  FROM `${work_dataset}.accession_citations_typed` GROUP BY 1
),
pop AS (
  SELECT family, accession,
    COUNT(DISTINCT publication_id) n_citing_articles
  FROM `${work_dataset}.accession_citations_typed` GROUP BY 1, 2
),
base AS (
  -- reference_db_prior rows are dropped: that rule is a blanket family default, not evidence,
  -- so keeping them would teach the model the prior instead of the signal.
  SELECT DISTINCT t.publication_id, t.accession, t.family, t.type, t.rule_applied,
    EXISTS (SELECT 1 FROM `${work_dataset}.accession_contexts` x
            WHERE x.publication_id = t.publication_id AND x.accession = t.accession)
      AS verified_in_text
  FROM `${work_dataset}.accession_citations_typed` t
  WHERE t.type != 'Excluded' AND t.rule_applied != 'reference_db_prior'
)
SELECT b.*,
  f.fp_risk, f.default_type_prior,
  IFNULL(c.n_mentions, 0) n_mentions, IFNULL(c.n_locations, 0) n_locations,
  IFNULL(c.in_availability, FALSE) in_availability, IFNULL(c.in_body, FALSE) in_body,
  IFNULL(c.in_abstract, FALSE) in_abstract, IFNULL(c.in_table_rows, FALSE) in_table_rows,
  IFNULL(c.in_references, FALSE) in_references,
  IFNULL(c.avg_sentence_len, 0) avg_sentence_len, IFNULL(c.bare_id_share, 1.0) bare_id_share,
  IFNULL(cue.cue_score, 0) cue_score,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'deposited'), FALSE)     cue_deposited,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'downloaded'), FALSE)    cue_downloaded,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'obtained_from'), FALSE) cue_obtained,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'made_available'), FALSE) cue_available,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'this_study_gen|datasets_generated|newly_generated'), FALSE) cue_generated,
  IFNULL(REGEXP_CONTAINS(cue.all_cues, 'reference_genome|aligned_mapped'), FALSE) cue_reference_use,
  a.pub_year, a.n_authors, a.title_data_paper, a.journal_data_venue,
  s.n_accession_pairs_in_article, s.n_families_in_article,
  pop.n_citing_articles,
  -- Label block. Training rows only; rows to be scored keep label NULL.
  CASE WHEN b.rule_applied LIKE 'repo_%' AND b.type IN ('Primary','Secondary') THEN b.type
       WHEN b.rule_applied IN ('cue_primary','cue_secondary','llm_enriched_secondary',
            'kaggle_emdb_rule','cue_primary_not_first','llm_primary_not_first',
            'llm_enriched_primary_not_first','repo_org_date_primary_not_first',
            'repo_author_date_primary_not_first') AND b.type IN ('Primary','Secondary') THEN b.type
       ELSE NULL END AS label,
  -- Per-rule confidence. Retained for analysis and for weighted experiments; note the shipped
  -- R1 model did NOT consume it (the training query excludes the column).
  CASE
    WHEN b.rule_applied IN ('repo_linked_pub_primary','repo_linked_other_secondary',
                            'repo_org_date_primary','repo_project_of_primary') THEN 1.0
    WHEN b.rule_applied IN ('repo_author_date_primary','repo_deposit_precedes_secondary') THEN 0.97
    WHEN b.rule_applied = 'llm_enriched_secondary' THEN 0.93
    WHEN b.rule_applied = 'cue_secondary' THEN 0.90
    WHEN b.rule_applied = 'kaggle_emdb_rule' THEN 0.85
    WHEN b.rule_applied = 'cue_primary' THEN 0.82
    WHEN b.rule_applied LIKE '%_not_first' THEN 0.80
    ELSE NULL END AS sample_weight,
  (b.rule_applied LIKE 'repo_%') AS eval_grade_label,   -- train/eval only on evidence labels
  -- Split by PUBLICATION, not by row: the leakage guard. Rows from one article share features
  -- (n_accession_pairs_in_article, the article's own metadata), so splitting per row would put
  -- correlated rows on both sides and flatter the model.
  CASE MOD(ABS(FARM_FINGERPRINT(b.publication_id)), 10)
    WHEN 8 THEN 'val' WHEN 9 THEN 'test' ELSE 'train' END AS split
FROM base b
LEFT JOIN `${work_dataset}.accession_families` f USING (family)
LEFT JOIN ctx c USING (publication_id, accession)
LEFT JOIN cue USING (publication_id, accession)
LEFT JOIN art a USING (publication_id)
LEFT JOIN sib s USING (publication_id)
LEFT JOIN pop USING (family, accession);

-- Score only the rows still undecided after the rule and evidence tiers.
CREATE OR REPLACE TABLE `${work_dataset}.model_scores`
CLUSTER BY family, accession AS
SELECT publication_id, accession, family,
  (SELECT prob FROM UNNEST(predicted_label_probs) WHERE label = 'Primary') p_primary
FROM ML.PREDICT(MODEL `${type_model}`, (
  SELECT f.* EXCEPT (type, rule_applied, sample_weight, eval_grade_label, split)
  FROM `${work_dataset}.model_features` f
  JOIN `${work_dataset}.accession_citations_typed` t USING (publication_id, accession)
  WHERE t.type = 'Unclassified'));

-- Write back ONLY confident calls. The 0.10 < p < 0.85 band is left Unclassified on purpose:
-- that is the precision floor (validated at 0.935 / 0.974 precision on val), and shipping the
-- middle band would trade honesty for coverage.
--
-- EXTRAPOLATION GUARD (added 2026-09-04, then narrowed the same day — read both halves).
--
-- Training labels come from the repository-evidence tier, which can only label families we
-- hold deposit records for. Eight families have NO such records and therefore contributed
-- ZERO training labels: dbgap, gisaid, arrayexpress, pxd, empiar, metabolights, biomodels,
-- biostudies. The model scores them anyway, which is out-of-distribution prediction.
--
-- The first version of this guard withheld ALL model claims in those families (15,534 rows),
-- on the strength of an apparent symptom: `pxd` runs 84.5% Primary across the rules that do
-- decide it while the model called only 1.1% of its pxd pairs Primary. **That reasoning was
-- wrong and the guard was too broad.** Every one of pxd's Primary rows comes from
-- `cue_primary` — the mention-context lexicon — so 84.5% is the Primary rate among pairs whose
-- text explicitly said "deposited". The model's population is the cue-UNDECIDED residue, where
-- the absence of deposition language genuinely predicts Secondary. The two figures describe
-- different populations, so the "divergence" was a selection artefact, not error.
--
-- Direct measurement supports the model here: of its confident calls in those eight families,
-- 27 are checkable against the gold sets and 27 are correct (Wilson lower bound ~0.87, over
-- the 0.8 floor). By this project's own rule that is a pass, so withholding them was not
-- justified.
--
-- What the evidence CANNOT cover is Primary calls: all 27 checkable cases were Secondary, and
-- the gold sets contain no Primary case in any of these families, so a Primary claim there is
-- wholly untested. Those are also rare — 350 rows against 15,184 Secondary. So the guard is
-- class-scoped rather than family-scoped: Secondary calls are allowed everywhere, Primary
-- calls only where the model has ground truth for the family. That costs 350 rows instead of
-- 15,534 and withholds exactly the claims nothing can check.
--
-- Computed from the table rather than hardcoded as a family list, deliberately: if an
-- api_fetch fetcher is added for PRIDE, `pxd` starts accruing deposit-evidence labels and
-- becomes eligible automatically, with nobody having to remember this comment. Same reasoning
-- as deriving the stage sequence from the directory instead of listing it.
--
-- Withheld predictions are still retained in `model_scores`, so per-family precision can be
-- measured later if gold Primary cases ever appear for these families.
UPDATE `${work_dataset}.accession_citations_typed` t
SET type = CASE WHEN s.p_primary >= 0.85 THEN 'Primary' ELSE 'Secondary' END,
    rule_applied = CASE WHEN s.p_primary >= 0.85 THEN 'model_primary' ELSE 'model_secondary' END
FROM (SELECT publication_id, accession, ANY_VALUE(p_primary) p_primary
      FROM `${work_dataset}.model_scores`
      WHERE
        -- Secondary: allowed in every family (27/27 on the gold-checkable subset).
        p_primary <= 0.10
        -- Primary: only where the model has ground truth for this family. Runs after stage
        -- 67, so the repo_* labels are already present in the table being read.
        OR (p_primary >= 0.85 AND family IN (
              SELECT family FROM `${work_dataset}.accession_citations_typed`
              WHERE STARTS_WITH(rule_applied, 'repo_')
              GROUP BY family))
      GROUP BY 1, 2) s
WHERE t.publication_id = s.publication_id AND t.accession = s.accession
  AND t.type = 'Unclassified'
