-- DataCite snapshot dedup: DOI universe for matching (excludes IGSN/arXiv-aliased records).
-- IGSN stays excluded here deliberately: at 9.4M records (6.9% of the whole DataCite
-- universe, concentrated in ~19 prefixes -- SESAR and Geoscience Australia dominate) it was
-- previously included and made this stage's matching too slow. IGSN support (added 2026-10)
-- instead uses a separate, small-universe path -- see 45_igsn_universe.sql /
-- 46_igsn_candidates.sql / 47_igsn_matches.sql -- that extracts candidates only from sentences
-- actually containing an igsn:/IGSN: label (rare) before joining against the IGSN-only
-- universe, rather than growing this 124M-row universe and its batch matching loop by 7.6%
-- for a volume of citations likely nowhere near proportional to that.
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
