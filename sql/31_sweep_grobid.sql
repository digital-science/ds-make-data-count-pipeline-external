-- COST WARNING: scans the ENTIRE fulltext column of ${fulltext_publications} regardless of candidate count. Dry-run first; the runner enforces a cost cap.
CREATE OR REPLACE TABLE `${work_dataset}.sweep_grobid`
CLUSTER BY id AS
SELECT c.id, p.fulltext
FROM `${fulltext_publications}` p, UNNEST(p.publication_ids) pid
INNER JOIN `${work_dataset}.sweep_candidates` c ON pid = c.id
