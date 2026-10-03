-- Batched matching of sentence DOI tokens against the DataCite snapshot (prefix equality + tail STARTS_WITH)
CREATE OR REPLACE PROCEDURE `${work_dataset}.process_dois_by_batch`(batch_from INT64, batch_to INT64)
BEGIN
  EXECUTE IMMEDIATE FORMAT('''
    INSERT INTO `${work_dataset}.datacite_sentence_matches`
      (publication_id, location, doi_prefixes, text, doibit_tail, doi)
    WITH source_batch AS (
      SELECT doi FROM `${work_dataset}.datacitesnapshot_no_igsnarxiv_r` t WHERE t.rownumber BETWEEN %d AND %d),
    doi_tail AS (
      SELECT DISTINCT LOWER(sb.doi) doi,
             LOWER(SUBSTR(sb.doi, 1, INSTR(sb.doi,'/')-1)) doi_prefixes,
             LOWER(SUBSTR(sb.doi, INSTR(sb.doi,'/')+1)) doi_tail
      FROM source_batch sb)
    SELECT sm.publication_id, sm.location, sm.doi_prefixes, sm.text, sm.doibit_tail, dt.doi
    FROM `${work_dataset}.sweep_doi_tokens` sm
    INNER JOIN doi_tail dt ON dt.doi_prefixes = sm.doi_prefixes
                          AND STARTS_WITH(sm.doibit_tail, dt.doi_tail)''', batch_from, batch_to);
END
