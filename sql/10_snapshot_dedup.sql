-- DataCite snapshot dedup: DOI universe for matching (excludes IGSN/arXiv-aliased records)
CREATE OR REPLACE TABLE `${work_dataset}.datacitesnapshot_no_igsnarxiv` AS
SELECT attributes.doi
FROM `${datacite_records}`
     LEFT JOIN UNNEST(attributes.alternateIdentifiers) alt_ids
GROUP BY 1
HAVING COUNTIF(alt_ids.alternateIdentifierType IN ('IGSN', 'arXiv')) = 0;

CREATE OR REPLACE TABLE `${work_dataset}.datacitesnapshot_no_igsnarxiv_r` AS
SELECT doi, ROW_NUMBER() OVER (ORDER BY doi) rownumber
FROM `${work_dataset}.datacitesnapshot_no_igsnarxiv`
ORDER BY doi
