-- Accession in-text verification + mention context capture (exact case-sensitive match)
CREATE OR REPLACE TABLE `${work_dataset}.accession_contexts`
CLUSTER BY family, accession AS
SELECT c.publication_id, c.accession, c.family, s.location, s.text AS sentence
FROM `${work_dataset}.accession_candidates` c
JOIN `${work_dataset}.sweep_sentences` s ON s.publication_id = c.publication_id
WHERE c.publication_id IS NOT NULL AND STRPOS(s.text, c.accession) > 0
