-- Widened sweep candidate set: DOI candidates UNION accession-bearing articles
CREATE OR REPLACE TABLE `${work_dataset}.sweep_candidates` AS
SELECT DISTINCT id FROM (
  SELECT id FROM `${work_dataset}.doi_candidates`
  UNION ALL
  SELECT publication_id AS id FROM `${work_dataset}.accession_candidates`
  WHERE publication_id IS NOT NULL AND has_fulltext)
