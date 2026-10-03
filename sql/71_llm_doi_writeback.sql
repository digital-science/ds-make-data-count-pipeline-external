-- LLM tier for the DOI arm: apply PRIMARY verdicts to rows the rule cascade left Unclassified.
--
-- Reads `llm_doi_primary_scores`, which is produced by the PAID, MANUAL step in
-- sql/manual/llm_doi_primary_v3.sql (BigQuery AI.GENERATE over Vertex gemini-2.5-flash-lite).
-- That separation is deliberate: inference costs money and needs approval, so the pipeline
-- consumes cached verdicts and never generates them. If the manual step has never run, the
-- CREATE TABLE IF NOT EXISTS below makes this stage a harmless no-op rather than an error --
-- the same reasoning as 39_sentence_matches_init.sql.
--
-- ONLY the PRIMARY verdict is applied. Measured on 117 human labels of the residue
-- (Simon, 2026-09-04):
--     PRIMARY     n=63  precision 0.937  (95% CI 0.85-0.98)   <- applied here
--     SECONDARY   n=75  precision 0.560                        <- NOT applied, ever
--     UNCLEAR                                                  <- not applied
-- The asymmetry is structural rather than a tuning artefact: explicit self-referential wording
-- ("the data underpinning the analysis reported in this paper") is real positive evidence of
-- primary deposit, but its ABSENCE is not evidence of reuse. Applying the SECONDARY verdict
-- would write at 0.56 precision. Leave those Unclassified.
--
-- Must run AFTER stage 65. Two reasons: it should only fill rows still Unclassified once the
-- uniqueness pass has finished moving things, and its own uniqueness guard (below) reads the
-- final set of Primaries. Numbered 71 because 66-69 are the accession tiers and 70 is a VIEW --
-- a stored query, so modifying the table after it is created is immaterial to what it returns.
--
-- Stage 61's author-name fix is complementary, not redundant: on the labelled sample only 29
-- rows of a 121-row union were flagged by both, and where the two disagree it is a coin flip
-- which is right (LLM 0.534 / name fix 0.466 over 88 disagreements). Where they AGREE precision
-- was 29/29. The two tiers recover largely different rows.

CREATE TABLE IF NOT EXISTS `${work_dataset}.llm_doi_primary_scores`
(
  publication_id    STRING,
  dataset_doi       STRING,
  cell              STRING,
  sentence_location STRING,
  sentence          STRING,
  llm_raw           STRING
);

UPDATE `${work_dataset}.doi_citations_typed` t
SET type = 'Primary', rule_applied = 'llm_primary'
FROM (
  WITH verdicts AS (
    -- Regex-extract rather than compare the raw string: ~6% of responses were verbose in
    -- earlier runs on the accession arm. This run parsed 68,878/68,878, but the guard costs
    -- nothing and a future model revision may be chattier.
    SELECT publication_id, dataset_doi,
           UPPER(REGEXP_EXTRACT(llm_raw, r'(?i)(PRIMARY|SECONDARY|NOT_DATA|UNCLEAR)')) AS verdict
    FROM `${work_dataset}.llm_doi_primary_scores`
  ),
  primaries AS (
    -- Dedup-guarded: one row per pair, so the UPDATE ... FROM cannot fan out. The current
    -- scores table is already 1:1 (16,339 rows, 16,339 distinct pairs) but a re-run of the
    -- manual step appends rather than replaces, so do not rely on that holding.
    SELECT publication_id, dataset_doi
    FROM verdicts WHERE verdict = 'PRIMARY'
    GROUP BY 1, 2
  ),
  -- A dataset has one generating paper (stage 65's rationale). 237 of the 16,339 verdicts name
  -- a dataset that ALREADY has a Primary from a stronger rule -- supplement_to (a DataCite
  -- assertion) or metadata_match. Those defer to the existing Primary and stay Unclassified:
  -- promoting them would create a second generating paper, and asserting Secondary instead
  -- would claim something neither the LLM nor any measurement supports.
  already_claimed AS (
    SELECT DISTINCT dataset_doi FROM `${work_dataset}.doi_citations_typed` WHERE type = 'Primary'
  )
  SELECT p.publication_id, p.dataset_doi
  FROM primaries p
  LEFT JOIN already_claimed a USING (dataset_doi)
  WHERE a.dataset_doi IS NULL
) d
WHERE t.publication_id = d.publication_id
  AND t.dataset_doi = d.dataset_doi
  -- Only ever fills gaps. A row already decided by any rule keeps that decision, so this stage
  -- can never overwrite stronger evidence and is idempotent on re-run.
  AND t.type = 'Unclassified';
