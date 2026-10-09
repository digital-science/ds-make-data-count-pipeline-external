-- Recall audit ground truth: dataset->article relations asserted in DataCite
CREATE OR REPLACE TABLE `${work_dataset}.recall_groundtruth` AS
SELECT DISTINCT
  LOWER(r.attributes.doi)                                  AS dataset_doi,
  SPLIT(r.attributes.doi, '/')[SAFE_OFFSET(0)]             AS dataset_prefix,
  r.attributes.types.resourceTypeGeneral                   AS resource_type,
  r.relationships.client.data.id                                    AS client_id,
  rel.relationType                                         AS relation_type,
  LOWER(REGEXP_REPLACE(rel.relatedIdentifier, r'^https?://(dx\.)?doi\.org/', '')) AS article_doi
FROM `${datacite_records}` r,
     UNNEST(r.attributes.relatedIdentifiers) rel
WHERE rel.relatedIdentifierType = 'DOI'
  AND rel.relationType IN ('IsCitedBy', 'IsSupplementTo', 'IsReferencedBy', 'IsDescribedBy')
  AND r.attributes.types.resourceTypeGeneral IN (
        'Dataset','PhysicalObject','Software','Collection','Audiovisual','Image',
        'DataPaper','Model','ComputationalNotebook','Workflow','InteractiveResource')
  -- mirror the pipeline's scope exclusion (arXiv handled separately there). IGSN is in
  -- scope here too, matching stage 10 -- IGSNs are DataCite DOIs since the 2023 migration.
  AND NOT EXISTS (
        SELECT 1 FROM UNNEST(r.attributes.alternateIdentifiers) ai
        WHERE ai.alternateIdentifierType = 'arXiv')
  AND SPLIT(r.attributes.doi, '/')[SAFE_OFFSET(0)] != '10.48550'
