-- EuropePMC text-mined accession annotations joined to publications by PMCID (PMID fallback)
CREATE OR REPLACE TABLE `${work_dataset}.accession_candidates`
CLUSTER BY family, accession AS
WITH pubs AS (
  SELECT id, pmcid, pmid
  FROM `${publications_metadata}`
  WHERE pmcid IS NOT NULL OR pmid IS NOT NULL
),
fulltext_ids AS (
  SELECT DISTINCT pid AS id
  FROM `${fulltext_publications}` p, UNNEST(p.publication_ids) pid
),
tmt AS (
  SELECT accession, family, pmcid, ext_id, source
  FROM `${work_dataset}.eupmc_text_mined_terms`
)
SELECT
  t.accession, t.family, t.pmcid, t.ext_id, t.source,
  COALESCE(p1.id, p2.id) AS publication_id,
  (ft.id IS NOT NULL)    AS has_fulltext,
  (dpp.id IS NOT NULL)   AS in_doi_candidate_set
FROM tmt t
LEFT JOIN pubs p1 ON p1.pmcid = t.pmcid
LEFT JOIN pubs p2 ON t.source = 'MED' AND p2.pmid = t.ext_id AND p1.id IS NULL
LEFT JOIN fulltext_ids ft ON ft.id = COALESCE(p1.id, p2.id)
LEFT JOIN `${work_dataset}.doi_candidates` dpp ON dpp.id = COALESCE(p1.id, p2.id)
-- One candidate per (article, accession, family). Europe PMC annotates some articles under two
-- records -- the MEDLINE record (source MED, ext_id = PMID) and the PMC full-text record (source
-- PMC, ext_id = PMCID), or two PMIDs sharing one PMCID -- and both resolve to the same Dimensions
-- publication. Without this every such citation shipped twice (2,117 duplicate keys, 2,110 in
-- the 202609 product; measured 2026-09-27) and stage 50 captured its mention contexts twice.
-- Nothing downstream reads source/ext_id/pmcid, so the choice of survivor cannot change a
-- decision; the PMC record is kept for determinism. Unresolved rows (no publication_id) are
-- partitioned by their own record and pass through unchanged.
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY COALESCE(COALESCE(p1.id, p2.id), CONCAT('unresolved:', t.source, ':', t.ext_id)),
               t.accession, t.family
  ORDER BY IF(t.source = 'PMC', 0, 1), t.ext_id) = 1
