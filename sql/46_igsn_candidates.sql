-- IGSN candidate extraction: the cheap side of the separate IGSN path (see 45_igsn_universe.sql
-- for why this is separate from stage 40/41). Filters sweep_sentences down to the rare subset
-- that actually mentions "igsn" BEFORE doing any string splitting -- this is the step that
-- keeps the IGSN path cheap regardless of the 9.4M-row universe, because the expensive side
-- of the eventual join (47_igsn_matches.sql) is this small candidate set, not the universe.
--
-- Citation formats seen in practice (verified against DataCite's own IGSN metadata
-- recommendations and simulated against this exact splitting logic before shipping):
--   "IGSN:10.58052/HRV003M16"                  -- bare form, needs the IGSN:/igsn: normalization
--   "igsn:https://doi.org/10.58052/IEGRW002B"  -- URL form, already matched by stage 40's logic
--                                                  incidentally (the doi.org/ segment splits
--                                                  cleanly on '/' regardless of the igsn: label)
-- Only the bare form actually needed this stage to exist; the URL form would work even
-- unscoped, but is included here too so IGSN matching lives in one place.
CREATE OR REPLACE TABLE `${work_dataset}.igsn_doi_tokens` AS
WITH igsn_prefixes AS (
  SELECT DISTINCT SPLIT(doi,'/')[SAFE_OFFSET(0)] doi_prefixes
  FROM `${work_dataset}.igsn_doi_universe`
),
candidate_sentences AS (
  -- Cheap filter first: cuts sweep_sentences down before any splitting work.
  SELECT publication_id, location, text
  FROM `${work_dataset}.sweep_sentences`
  WHERE REGEXP_CONTAINS(text, r'(?i)igsn')
)
SELECT DISTINCT t.publication_id, t.location, igsn_prefixes.doi_prefixes, t.text,
       LOWER(colonbits) doibits,
       (SELECT STRING_AGG(x, '/' ORDER BY to3) FROM UNNEST(ARRAY(
          (SELECT LOWER(sb2) FROM UNNEST(SPLIT(colonbits,'/')) sb2 WITH OFFSET AS token_offset2
           WHERE token_offset2 > token_offset ORDER BY token_offset2))) x WITH OFFSET AS to3) doibit_tail
FROM candidate_sentences t,
     -- Same normalization stage 40 does for "DOI:" -> "doi:", extended to the IGSN label so
     -- the bare form ("IGSN:10.58052/...") is found the same way a bare DOI citation is.
     UNNEST(SPLIT(REPLACE(REPLACE(REPLACE(REPLACE(t.text,' ',''),
            'DOI:','doi:'),'IGSN:','doi:'),'igsn:','doi:'), 'doi:')) colonbits,
     UNNEST(SPLIT(colonbits,'/')) slashbits WITH OFFSET AS token_offset
INNER JOIN igsn_prefixes ON igsn_prefixes.doi_prefixes = slashbits
