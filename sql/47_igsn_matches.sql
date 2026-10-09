-- IGSN matching: joins the small candidate set from 46_igsn_candidates.sql against the small
-- universe from 45_igsn_universe.sql. No batching needed (unlike stage 41's
-- process_dois_by_batch) because both sides are small by construction -- the whole point of
-- keeping this path separate from the main DOI universe.
--
-- Inserts into the SAME datacite_sentence_matches table stage 41 populates (identical schema),
-- so everything downstream -- stage 43's dedup, stage 44's reference remapping, typing,
-- classification -- treats an IGSN match exactly like any other DOI match with zero changes.
-- Must run after stage 39 (creates the table) and before stage 43 (consumes it); ordering is
-- handled automatically since run_pipeline.py globs sql/*.sql in sorted filename order and 39
-- and 43 sort either side of 45-47.
INSERT INTO `${work_dataset}.datacite_sentence_matches`
  (publication_id, location, doi_prefixes, text, doibit_tail, doi)
WITH doi_tail AS (
  SELECT DISTINCT LOWER(u.doi) doi,
         LOWER(SUBSTR(u.doi, 1, INSTR(u.doi,'/')-1)) doi_prefixes,
         LOWER(SUBSTR(u.doi, INSTR(u.doi,'/')+1)) doi_tail
  FROM `${work_dataset}.igsn_doi_universe` u)
SELECT sm.publication_id, sm.location, sm.doi_prefixes, sm.text, sm.doibit_tail, dt.doi
FROM `${work_dataset}.igsn_doi_tokens` sm
INNER JOIN doi_tail dt ON dt.doi_prefixes = sm.doi_prefixes
                      AND STARTS_WITH(sm.doibit_tail, dt.doi_tail)
