-- SRAD spine: one row per (release, article, dataset identifier), with the decision, the rule
-- that made it, and the tier that rule belongs to.
--
-- `tier` is the navigation column: it tells a researcher which SINGLE evidence table to join
-- rather than joining all five. It is derived from rule_applied here rather than stored upstream,
-- so it cannot disagree with `srad.rules`.
--
-- Partitioned by release_date (a DATE derived from the release id) because BigQuery cannot
-- partition on a STRING. `release` remains the human-facing identifier; queries should filter on
-- release_date for partition pruning and read `release` for display.
CREATE OR REPLACE TABLE `${srad_dataset}.citations`
PARTITION BY release_date
CLUSTER BY publication_id, id_kind AS
WITH rel AS (
  SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
         DATE_TRUNC(CURRENT_DATE(), MONTH)   AS release_date
),
oa AS (
  SELECT id AS publication_id,
         doi AS article_doi,
         pmcid AS article_pmcid,
         'oa_all' IN UNNEST(open_access_categories_v2) AS is_open_access,
         ARRAY_TO_STRING(open_access_categories_v2, ',') AS open_access_categories
  FROM `${publications_metadata}`
)
SELECT
  rel.release,
  rel.release_date,
  v.publication_id,
  oa.article_doi,
  oa.article_pmcid,
  v.dataset_id,
  v.id_kind,
  v.family_or_repo,
  v.type,
  v.rule_applied,
  -- Tier, matching srad.rules.tier. Kept as an explicit CASE rather than a join so the spine
  -- has no dependency on registry load order, and so an unrecognised rule surfaces as
  -- 'UNMAPPED' instead of NULL -- a new rule added without updating the registry is then
  -- visible in one GROUP BY rather than silently absent.
  CASE
    WHEN v.rule_applied = 'supplement_to' THEN 'registered_relation'
    WHEN v.rule_applied IN ('metadata_match','metadata_match_not_first','popular_dataset',
                            'multi_cited_not_first') THEN 'metadata_similarity'
    WHEN v.rule_applied = 'llm_primary' THEN 'llm'
    WHEN v.rule_applied IN ('regex_invalid','band_notation','glycan_notation','reference_db_prior','kaggle_samn_rule',
                            'kaggle_emdb_rule','kaggle_samn_rule_not_first',
                            'kaggle_emdb_rule_not_first') THEN 'family_prior'
    WHEN STARTS_WITH(v.rule_applied, 'cue_') THEN 'mention_cue'
    WHEN STARTS_WITH(v.rule_applied, 'repo_') THEN 'repository_evidence'
    WHEN STARTS_WITH(v.rule_applied, 'model_') THEN 'model'
    WHEN v.rule_applied = 'residual' OR STARTS_WITH(v.rule_applied, 'residual_') THEN 'none'
    ELSE 'UNMAPPED'
  END AS tier,
  v.evidence_source,
  v.resource_type,
  v.is_data_type,
  -- Accession-arm provenance flags, as they actually exist on the typed table.
  -- NOTE: there is no stored `verified_in_text` column, despite methods.md documenting one.
  -- It is DERIVED here as "a mention context exists", which is what verification means in this
  -- pipeline: stage 50 only writes a context row when the accession string is found in a
  -- sentence by exact case-sensitive match. Deriving it is preferable to omitting it, and is
  -- labelled so nobody mistakes it for an upstream field.
  a.has_fulltext,
  a.regex_valid,
  a.fp_risk,
  a.default_type_prior,
  (m.publication_id IS NOT NULL) AS verified_in_text_derived,
  IFNULL(oa.is_open_access, FALSE) AS is_open_access,
  oa.open_access_categories
FROM `${work_dataset}.data_citations` v
LEFT JOIN oa USING (publication_id)
LEFT JOIN (
  SELECT publication_id, accession,
         ANY_VALUE(has_fulltext)        AS has_fulltext,
         ANY_VALUE(regex_valid)         AS regex_valid,
         ANY_VALUE(fp_risk)             AS fp_risk,
         ANY_VALUE(default_type_prior)  AS default_type_prior
  FROM `${work_dataset}.accession_citations_typed`
  GROUP BY 1, 2
) a ON a.publication_id = v.publication_id AND a.accession = v.dataset_id
LEFT JOIN (
  SELECT DISTINCT publication_id, accession FROM `${work_dataset}.accession_contexts`
) m ON m.publication_id = v.publication_id AND m.accession = v.dataset_id
CROSS JOIN rel;
