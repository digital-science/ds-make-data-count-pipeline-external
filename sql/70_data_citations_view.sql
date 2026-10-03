-- Unified product view: one row per (article, dataset id) with type, rule, evidence source
CREATE OR REPLACE VIEW `${work_dataset}.data_citations` AS
SELECT publication_id,
       dataset_doi          AS dataset_id,
       'doi'                AS id_kind,
       client_id            AS family_or_repo,
       type, rule_applied,
       'grobid_text_mined'  AS evidence_source,
       is_data_type,
       resource_type
FROM `${work_dataset}.doi_citations_typed`
UNION ALL
SELECT publication_id,
       accession            AS dataset_id,
       'accession'          AS id_kind,
       family               AS family_or_repo,
       type, rule_applied,
       'eupmc_text_mined'   AS evidence_source,
       TRUE                 AS is_data_type,
       CAST(NULL AS STRING) AS resource_type
FROM `${work_dataset}.accession_citations_typed`
WHERE type != 'Excluded'
