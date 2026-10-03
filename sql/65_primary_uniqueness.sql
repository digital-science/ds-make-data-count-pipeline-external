-- Per-dataset Primary uniqueness (post-pass after 61/64):
-- inference-based Primary assignments (metadata_match, cue_primary, forced family rules) are
-- demoted to Secondary for all but the EARLIEST citing paper of each dataset. Rows sharing the
-- earliest paper's normalized title ride along (preprint/published pairs are the same work).
-- Repository-asserted supplement_to Primaries are exempt. Demotions get an auditable
-- '*_not_first' rule label. Rationale: a dataset has one generating paper; same-group
-- follow-ups reusing their own data are Secondary under the Primary/Secondary definition.

UPDATE `${work_dataset}.doi_citations_typed` t
SET type = 'Secondary', rule_applied = 'metadata_match_not_first'
FROM (
  WITH prim AS (
    SELECT publication_id, dataset_doi, pub_year,
           IFNULL(author_overlap_frac,0) + IFNULL(title_jaccard,0) AS sim,
           REGEXP_REPLACE(LOWER(IFNULL(pub_title,'')), r'[^a-z0-9]', '') AS norm_title
    FROM `${work_dataset}.doi_citations_typed`
    WHERE type = 'Primary' AND rule_applied = 'metadata_match'
  ),
  ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY dataset_doi
                ORDER BY pub_year IS NULL, pub_year, sim DESC, publication_id) rn
    FROM prim
  ),
  earliest AS (SELECT dataset_doi, norm_title FROM ranked WHERE rn = 1)
  SELECT DISTINCT r.publication_id, r.dataset_doi
  FROM ranked r JOIN earliest e USING (dataset_doi)
  WHERE r.rn > 1 AND NOT (r.norm_title = e.norm_title AND r.norm_title != '')
) d
WHERE t.publication_id = d.publication_id AND t.dataset_doi = d.dataset_doi
  AND t.type = 'Primary' AND t.rule_applied = 'metadata_match';

UPDATE `${work_dataset}.accession_citations_typed` t
SET type = 'Secondary', rule_applied = CONCAT(t.rule_applied, '_not_first')
FROM (
  WITH prim AS (
    SELECT DISTINCT t.publication_id, t.accession, t.family, p.year,
           REGEXP_REPLACE(LOWER(IFNULL(p.title.preferred,'')), r'[^a-z0-9]', '') AS norm_title
    FROM `${work_dataset}.accession_citations_typed` t
    JOIN `${publications_metadata}` p ON p.id = t.publication_id
    WHERE t.type = 'Primary'
      AND t.rule_applied IN ('cue_primary', 'kaggle_samn_rule', 'kaggle_emdb_rule')
  ),
  ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY family, accession
                ORDER BY year IS NULL, year, publication_id) rn
    FROM prim
  ),
  earliest AS (SELECT family, accession, norm_title FROM ranked WHERE rn = 1)
  SELECT DISTINCT r.publication_id, r.accession, r.family
  FROM ranked r JOIN earliest e USING (family, accession)
  WHERE r.rn > 1 AND NOT (r.norm_title = e.norm_title AND r.norm_title != '')
) d
WHERE t.publication_id = d.publication_id AND t.accession = d.accession AND t.family = d.family
  AND t.type = 'Primary';
