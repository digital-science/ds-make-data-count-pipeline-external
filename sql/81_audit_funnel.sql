-- Recall audit funnel: in-corpus -> has-fulltext -> in-prefilter -> pair-recovered
CREATE OR REPLACE TABLE `${work_dataset}.recall_funnel` AS
WITH pubs AS (
  SELECT id, LOWER(doi) AS doi, year
  FROM `${publications_metadata}`
  WHERE doi IS NOT NULL
    AND year BETWEEN 2015 AND 2026
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LOWER(doi) ORDER BY id) = 1
),
-- cheap: only the publication_ids column of the fulltext table is read, never fulltext itself
fulltext_ids AS (
  SELECT DISTINCT pid AS id
  FROM `${fulltext_publications}` p,
       UNNEST(p.publication_ids) pid
),
matches AS (
  SELECT DISTINCT publication_id, LOWER(doi) AS dataset_doi
  FROM `${work_dataset}.datacite_sentence_matches_confirmed_remapped`
)
SELECT
  gt.*,
  p.id                            AS publication_id,
  p.year                          AS article_year,
  (ft.id IS NOT NULL)             AS has_fulltext,
  (pp.id IS NOT NULL)             AS in_prefilter,
  (m.publication_id IS NOT NULL)  AS pair_recovered
FROM `${work_dataset}.recall_groundtruth` gt
LEFT JOIN pubs p              ON p.doi = gt.article_doi
LEFT JOIN fulltext_ids ft     ON ft.id = p.id
LEFT JOIN `${work_dataset}.doi_candidates` pp ON pp.id = p.id
LEFT JOIN matches m           ON m.publication_id = p.id
                             AND m.dataset_doi = gt.dataset_doi
