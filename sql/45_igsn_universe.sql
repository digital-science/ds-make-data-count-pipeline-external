-- IGSN universe: the DataCite DOI records explicitly excluded from the main DOI universe by
-- stage 10 (9.4M records, 6.9% of all DataCite -- concentrated in ~19 prefixes, SESAR and
-- Geoscience Australia dominant). Kept as its own small table rather than folded into
-- datacitesnapshot_no_igsnarxiv: that table drives stage 41's batched matching loop, which
-- scales with total row count, and growing it by 9.4M records for a citation volume likely
-- far smaller was the original reason IGSN was excluded in the first place. See
-- 46_igsn_candidates.sql / 47_igsn_matches.sql for how this is actually matched.
CREATE OR REPLACE TABLE `${work_dataset}.igsn_doi_universe` AS
SELECT attributes.doi
FROM `${datacite_records}`
WHERE EXISTS(
  SELECT 1 FROM UNNEST(attributes.alternateIdentifiers) a WHERE a.alternateIdentifierType = 'IGSN');
