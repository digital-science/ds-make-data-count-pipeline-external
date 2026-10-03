-- Longest-DOI-wins dedup per (article, sentence, tail): version disambiguation
CREATE OR REPLACE TABLE `${work_dataset}.datacite_sentence_matches_confirmed` AS
WITH maxl AS (
  SELECT publication_id, text, doibit_tail, MAX(LENGTH(doi)) maxl
  FROM `${work_dataset}.datacite_sentence_matches` GROUP BY 1,2,3)
SELECT DISTINCT sm.publication_id, sm.doi, sm.location, sm.text, sm.doibit_tail
FROM `${work_dataset}.datacite_sentence_matches` sm
INNER JOIN maxl ON sm.publication_id = maxl.publication_id
              AND sm.doibit_tail = maxl.doibit_tail AND sm.text = maxl.text
              AND LENGTH(sm.doi) = maxl.maxl
