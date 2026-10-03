-- DOI token extraction: whitespace-stripped, doi:-normalized prefix/tail tokens per sentence
CREATE OR REPLACE TABLE `${work_dataset}.sweep_doi_tokens` AS
WITH doi_prefixes AS (
  SELECT DISTINCT SPLIT(doi,'/')[SAFE_OFFSET(0)] doi_prefixes
  FROM `${work_dataset}.datacitesnapshot_no_igsnarxiv`
)
SELECT DISTINCT t.publication_id, t.location, doi_prefixes.doi_prefixes, t.text,
       LOWER(colonbits) doibits,
       (SELECT STRING_AGG(x, '/' ORDER BY to3) FROM UNNEST(ARRAY(
          (SELECT LOWER(sb2) FROM UNNEST(SPLIT(colonbits,'/')) sb2 WITH OFFSET AS token_offset2
           WHERE token_offset2 > token_offset ORDER BY token_offset2))) x WITH OFFSET AS to3) doibit_tail
FROM `${work_dataset}.sweep_sentences` t,
     UNNEST(SPLIT(REPLACE(REPLACE(t.text,' ',''),'DOI:','doi:'),'doi:')) colonbits,
     UNNEST(SPLIT(colonbits,'/')) slashbits WITH OFFSET AS token_offset
INNER JOIN doi_prefixes ON doi_prefixes.doi_prefixes = slashbits
