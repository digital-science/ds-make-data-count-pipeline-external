-- DOI type classification: similarity features + rules cascade (thresholds pending gold-set tuning)
-- The cascade decides `type` from creator/title similarity and reuse counts. Mention-location
-- features (in_availability / via_reference, from stage 60) partition the Unclassified residue
-- for review but deliberately assign no type yet -- see the long note on the residual branches.
--
-- HAZARD: this stage is CREATE OR REPLACE and stage 65 (primary_uniqueness) mutates the
-- resulting table with UPDATEs afterwards. Re-running 61 on its own therefore DISCARDS
-- stage 65's demotions -- 45,580 metadata_match_not_first rows silently revert to Primary,
-- inflating Primary in the published product. Never invoke 61 standalone against a live
-- table; run the stage sequence so 65 follows it.
CREATE OR REPLACE TABLE `${work_dataset}.doi_citations_typed` AS
WITH feat AS (
  SELECT *,
    -- Author overlap: dataset creators vs article author last names.
    --
    -- ds_creator_names is built in stage 60 as COALESCE(c.familyName, c.name), so when DataCite
    -- omits familyName the entry holds a WHOLE NAME -- "anirudh raju natarajan", "antonio
    -- camargo", "garibay alonso", even the undelimited "linwenfang" -- while
    -- pub_author_lastnames holds bare surnames. A plain equality test can never match those,
    -- so the fallback rows scored zero overlap regardless of the truth. 27.2% of creator
    -- strings in the Unclassified residue are multi-token, i.e. the residue is ENRICHED in
    -- exactly this failure (spotted by eye in the review sample, 2026-09-04).
    --
    -- Fix: keep exact matching for single-token creators, which are already real family names,
    -- and add token matching ONLY for multi-token strings -- precisely where the fallback
    -- happened. Monotone by construction: it can add overlap, never remove it. Tokenising both
    -- sides also handles compound and hyphenated surnames ("garibay alonso" vs
    -- "garibay-alonso"). The >=3 char token floor keeps short surnames (kim, wu, lee) working;
    -- an earlier >=4 attempt silently LOST them and dropped metadata_match from 94.0% to 93.1%.
    --
    -- Validated as signal, not noise, on the two rule arms that are independent of this
    -- feature: gold Primary (supplement_to, from DataCite IsSupplementTo) rises 78.5% -> 97.6%
    -- while gold Secondary (popular_dataset, from reuse counts) moves only 4.5% -> 6.2%.
    -- 11:1 discrimination.
    --
    -- Undelimited names ("linwenfang" for Lin Wenfang) remain unfixable here: there is no
    -- boundary to tokenise on. Accepted limitation, not an oversight.
    (SELECT COUNT(DISTINCT c) FROM UNNEST(ds_creator_names) c
      WHERE c IN UNNEST(pub_author_lastnames)
         OR (ARRAY_LENGTH(REGEXP_EXTRACT_ALL(c, r'[a-z]{2,}')) > 1
             AND EXISTS (
               SELECT 1 FROM UNNEST(REGEXP_EXTRACT_ALL(c, r'[a-z]{3,}')) ct
               WHERE ct IN UNNEST(ARRAY(SELECT t FROM UNNEST(pub_author_lastnames) a,
                                        UNNEST(REGEXP_EXTRACT_ALL(a, r'[a-z]{3,}')) t))))
    ) AS author_overlap_cnt,
    -- The pre-fix strict count is retained alongside it. Labelling (2026-09-04, 117 rows of
    -- the Unclassified residue) showed the corrected count is the better FEATURE but must not
    -- relax the PROMOTION test: token-matched overlap promotes reliably only at a COMPLETE
    -- match. Precision by fixed-overlap fraction on those labels:
    --     frac = 1.00  0.838 (57/68)   <- over the 0.8 floor
    --     0.75-0.99    0.600 (3/5)
    --     0.50-0.74    0.556 (5/9)
    -- Partial token matches are 9/15 = 0.60 overall: a shared surname between one creator and
    -- one author is weak evidence on its own (common surnames, large author lists), whereas
    -- every creator appearing among the authors is strong. So the original arms below run on
    -- the exact count only, exactly as before the fix, and the corrected count adds a single
    -- new arm gated at frac = 1.0.
    (SELECT COUNT(DISTINCT c) FROM UNNEST(ds_creator_names) c
      WHERE c IN UNNEST(pub_author_lastnames)) AS author_overlap_exact,
    ARRAY_LENGTH(ds_creator_names) AS n_ds_creators,
    -- title token sets (words >= 3 chars, lowercased alnum)
    ARRAY(SELECT DISTINCT w FROM UNNEST(REGEXP_EXTRACT_ALL(LOWER(IFNULL(ds_title,'')),  r'[a-z0-9]{3,}')) w) AS ds_tokens,
    ARRAY(SELECT DISTINCT w FROM UNNEST(REGEXP_EXTRACT_ALL(LOWER(IFNULL(pub_title,'')), r'[a-z0-9]{3,}')) w) AS pub_tokens,
    pub_year - ds_year AS year_gap,
    resource_type IN ('Dataset','PhysicalObject','Software','Collection','Audiovisual','Image',
                      'DataPaper','Model','ComputationalNotebook','Workflow','InteractiveResource') AS is_data_type
  FROM `${work_dataset}.doi_pair_features`
),
scored AS (
  SELECT *,
    SAFE_DIVIDE(author_overlap_cnt, LEAST(IFNULL(n_ds_creators,0), ARRAY_LENGTH(pub_author_lastnames))) AS author_overlap_frac,
    SAFE_DIVIDE(author_overlap_exact, LEAST(IFNULL(n_ds_creators,0), ARRAY_LENGTH(pub_author_lastnames))) AS author_overlap_frac_exact,
    SAFE_DIVIDE(
      (SELECT COUNT(*) FROM UNNEST(ds_tokens) t WHERE t IN UNNEST(pub_tokens)),
      ARRAY_LENGTH(ARRAY(SELECT DISTINCT x FROM UNNEST(ARRAY_CONCAT(ds_tokens, pub_tokens)) x))
    ) AS title_jaccard
  FROM feat
)
SELECT * EXCEPT(ds_tokens, pub_tokens),
  CASE
    WHEN is_supplement_to_article THEN 'Primary'
    WHEN author_overlap_frac_exact >= 0.4
      OR (author_overlap_exact >= 2 AND title_jaccard >= 0.3)
      OR title_jaccard >= 0.6
      OR author_overlap_frac >= 1.0                    THEN 'Primary'
    WHEN n_citing_articles >= 5                        THEN 'Secondary'
    WHEN n_citing_articles BETWEEN 2 AND 4
         AND citing_rank > 1                           THEN 'Secondary'
    ELSE 'Unclassified'
  END AS type,
  CASE
    WHEN is_supplement_to_article THEN 'supplement_to'
    WHEN author_overlap_frac_exact >= 0.4
      OR (author_overlap_exact >= 2 AND title_jaccard >= 0.3)
      OR title_jaccard >= 0.6
      OR author_overlap_frac >= 1.0                    THEN 'metadata_match'
    WHEN n_citing_articles >= 5                        THEN 'popular_dataset'
    WHEN n_citing_articles BETWEEN 2 AND 4
         AND citing_rank > 1                           THEN 'multi_cited_not_first'
    -- Residue partitioned by mention LOCATION (2026-09-04). Stage 60 computes
    -- in_availability / in_body / in_abstract / via_reference from
    -- datacite_sentence_matches_confirmed_remapped and this cascade never consulted any of
    -- them, so the residue was one undifferentiated 313k bucket. These four labels leave
    -- `type` untouched -- every one is still Unclassified -- and only record which evidence
    -- the row carries, so the residue can be stratified, sampled and eventually decided.
    --
    -- Why no type is assigned yet. The location features ARE predictive: on the 303
    -- gold-labelled DOI-arm rows, in_availability AND NOT via_reference is 91% Primary
    -- (n=100) against a 72% base rate, and via_reference alone is 53% (n=97). But that gold
    -- set is itself 72% Primary, so its rates cannot be transferred to the residue, and the
    -- residue's own gold overlap is 26 rows (cells of 2/2/2/20) -- too thin to calibrate
    -- anything. Correcting for the base-rate difference by likelihood ratio puts the best
    -- available rule at ~79.5% precision: just UNDER the 0.8 floor, which means Unclassified.
    --
    -- Two earlier estimates of the residue's Primary fraction disagreed sharply and the
    -- disagreement is the point. A mixture model over these same location features implied
    -- p ~= 0.10-0.14 (which would make an authors-disjoint -> Secondary rule ~96% precise);
    -- the 26 gold-labelled rows measured p = 0.50 (which makes it ~80%, i.e. unshippable).
    -- The mixture model was wrong because it assumed residual Primaries look like gold
    -- Primaries, and they cannot: a residual row has zero author overlap by construction,
    -- while only 21.5% of gold Primaries do. Do not resurrect that estimate; it is
    -- structurally biased, not merely imprecise.
    --
    -- The gate is a human-labelled stratified sample across these four cells. When those
    -- labels exist, promoting a cell is a one-line change here -- e.g. a measured-precise
    -- residual_reference_only becomes 'authors_disjoint_reference_only' + Secondary in the
    -- type CASE above, mirroring 66_repo_evidence.sql's linked_other_secondary, which draws
    -- exactly this inference on the accession arm (submitters present + zero author overlap
    -- -> Secondary). Promote only cells whose sampled precision clears 0.8.
    WHEN in_availability AND NOT via_reference         THEN 'residual_availability_only'
    WHEN in_availability                               THEN 'residual_availability_ref'
    WHEN via_reference                                 THEN 'residual_reference_only'
    ELSE 'residual_no_location_signal'
  END AS rule_applied
FROM scored
