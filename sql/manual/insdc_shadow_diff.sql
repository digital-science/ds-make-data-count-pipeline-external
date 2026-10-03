-- Shadow diff for the targeted INSDC cache (DESIGN-targeted-insdc-fetch.md, Phase 2).
-- Read-only. Recomputes the stage-66 gen cascade for every gen pair three ways and compares:
--   A  lake only                               (production today; gates FALSE)
--   B  lake + cache, nucleotide rows only      (INSDC_ATTRIBUTION_ENABLED)
--   C  lake + cache, including protein rows    (both gates; Simon's protein decision)
-- The CASE is stage 66's, verbatim apart from the source, INCLUDING the exact-membership PMID
-- fix. Unlike stage 66 it does not skip pairs a repo rule already decided, because the current
-- typed table is post-writeback and that filter would hide exactly the pairs whose decision
-- could change.
WITH src AS (
  SELECT accession, submit_authors, submit_date, pubmed_ids, 'lake' AS s
  FROM `${work_dataset}.insdc_provenance`
  UNION ALL
  SELECT accession, submit_authors, submit_date, pubmed_ids, IF(db = 'protein', 'prot', 'nuc')
  FROM `${work_dataset}.insdc_attribution` WHERE found),
agg AS (
  SELECT UPPER(accession) acc, v,
         ANY_VALUE(submit_authors HAVING MAX LENGTH(submit_authors)) submit_authors,
         MAX(REGEXP_EXTRACT(submit_date, r'(\d{4})')) dep_year,
         STRING_AGG(DISTINCT pubmed_ids, '|') pubmeds
  FROM src, UNNEST(CASE s WHEN 'lake' THEN ['A','B','C'] WHEN 'nuc' THEN ['B','C'] ELSE ['C'] END) v
  GROUP BY 1, 2),
pairs AS (
  SELECT t.publication_id, t.accession, t.type cur_type, t.rule_applied cur_rule, p.pmid, p.doi,
         p.year pub_year,
         ARRAY(SELECT LOWER(au.last_name) FROM UNNEST(p.authors) au
               WHERE au.last_name IS NOT NULL AND LENGTH(au.last_name) >= 4) au_names
  FROM `${work_dataset}.accession_citations_typed` t
  JOIN `${publications_metadata}` p ON p.id = t.publication_id
  WHERE t.family = 'gen' AND t.type != 'Excluded'
    AND NOT REGEXP_CONTAINS(t.accession, r'^[SED]R[APRSXZ]\d{6,}$')),
dec AS (
  SELECT pr.publication_id, pr.accession, pr.cur_type, pr.cur_rule, pr.doi, vv AS v,
    CASE
      WHEN l.acc IS NULL THEN 'no_metadata_yet'
      WHEN pr.pmid IS NOT NULL AND pr.pmid IN UNNEST(SPLIT(IFNULL(l.pubmeds,''), '|'))
           THEN 'linked_pub_primary'
      WHEN l.pubmeds IS NOT NULL AND l.pubmeds != ''
           AND (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
                WHERE STRPOS(LOWER(IFNULL(l.submit_authors,'')), n) > 0) = 0 THEN 'linked_other_secondary'
      WHEN (SELECT COUNT(*) FROM UNNEST(pr.au_names) n
            WHERE STRPOS(LOWER(IFNULL(l.submit_authors,'')), n) > 0) >= 1
           AND SAFE_CAST(l.dep_year AS INT64) IS NOT NULL
           AND ABS(SAFE_CAST(l.dep_year AS INT64) - pr.pub_year) <= 1 THEN 'author_date_primary'
      WHEN SAFE_CAST(l.dep_year AS INT64) < pr.pub_year - 1 THEN 'deposit_precedes_secondary'
      ELSE 'undecided'
    END AS decision
  FROM pairs pr
  CROSS JOIN UNNEST(['A','B','C']) vv
  LEFT JOIN agg l ON l.acc = UPPER(pr.accession) AND l.v = vv)
SELECT publication_id, accession, doi, cur_type, cur_rule,
       MAX(IF(v = 'A', decision, NULL)) AS dec_a,
       MAX(IF(v = 'B', decision, NULL)) AS dec_b,
       MAX(IF(v = 'C', decision, NULL)) AS dec_c
FROM dec GROUP BY 1, 2, 3, 4, 5
