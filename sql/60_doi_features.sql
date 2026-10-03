-- Per-pair features: mention stats, dataset metadata (DataCite), article metadata, IsSupplementTo, citation ranks
CREATE OR REPLACE TABLE `${work_dataset}.doi_pair_features` AS
WITH pairs AS (
  SELECT publication_id,
         LOWER(doi) AS dataset_doi,
         COUNT(DISTINCT text) AS n_mention_sentences,
         LOGICAL_OR(location = 'availability_sentences') AS in_availability,
         LOGICAL_OR(location = 'body_sentences')         AS in_body,
         LOGICAL_OR(location = 'abstract_sentences')     AS in_abstract,
         LOGICAL_OR(original_location = 'references_titles') AS via_reference
  FROM `${work_dataset}.datacite_sentence_matches_confirmed_remapped`
  GROUP BY 1, 2
),
ds AS (
  SELECT LOWER(attributes.doi) AS dataset_doi,
         (SELECT t.title FROM UNNEST(attributes.titles) t WHERE t.title IS NOT NULL LIMIT 1) AS ds_title,
         attributes.publicationYear AS ds_year,
         r.relationships.client.data.id AS client_id,
         attributes.types.resourceTypeGeneral AS resource_type,
         ARRAY(SELECT LOWER(COALESCE(c.familyName, c.name)) FROM UNNEST(attributes.creators) c
               WHERE COALESCE(c.familyName, c.name) IS NOT NULL) AS ds_creator_names,
         ARRAY(SELECT LOWER(rel.relatedIdentifier) FROM UNNEST(attributes.relatedIdentifiers) rel
               WHERE rel.relationType = 'IsSupplementTo' AND rel.relatedIdentifierType = 'DOI') AS supplement_to_dois
  FROM `${datacite_records}` r
),
pub AS (
  SELECT id, LOWER(doi) AS pub_doi, year AS pub_year, title.preferred AS pub_title,
         ARRAY(SELECT LOWER(a.last_name) FROM UNNEST(authors) a WHERE a.last_name IS NOT NULL) AS pub_author_lastnames
  FROM `${publications_metadata}`
)
SELECT p.publication_id, p.dataset_doi,
       p.n_mention_sentences, p.in_availability, p.in_body, p.in_abstract, p.via_reference,
       ds.ds_title, ds.ds_year, ds.client_id, ds.resource_type, ds.ds_creator_names,
       pub.pub_doi, pub.pub_year, pub.pub_title, pub.pub_author_lastnames,
       EXISTS(SELECT 1 FROM UNNEST(ds.supplement_to_dois) s WHERE s = pub.pub_doi) AS is_supplement_to_article,
       COUNT(*)     OVER (PARTITION BY p.dataset_doi) AS n_citing_articles,
       ROW_NUMBER() OVER (PARTITION BY p.dataset_doi ORDER BY pub.pub_year NULLS LAST, p.publication_id) AS citing_rank
FROM pairs p
LEFT JOIN ds  ON ds.dataset_doi = p.dataset_doi
LEFT JOIN pub ON pub.id = p.publication_id
