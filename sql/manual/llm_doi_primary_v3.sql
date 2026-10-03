-- Candidate LLM tier for the DOI arm: recover PRIMARY citations from the Unclassified residue
-- by reading the mention sentence. NOT a pipeline stage -- deliberately in sql/manual/ (outside
-- the NN_*.sql glob that bq_stage_runner discovers) because a full run is paid inference and
-- needs explicit approval, exactly like train_type_clf_v1.sql.
--
-- MEASURED 2026-09-04 on 623 rows via BigQuery AI.GENERATE + Vertex gemini-2.5-flash-lite
-- (623 calls, ~$0.05, 100% parseable). Calibrated against the kaggle + rdmpage gold labels
-- joined to the DOI arm: 303 rows, which dedupe to 180 distinct pairs (the gold sets contain
-- 123 duplicate pair rows -- always dedupe before scoring).
--
--   verdict     n    precision
--   PRIMARY     78   0.962  (75/78)   <- usable, well over the 0.8 floor
--   SECONDARY   75   0.560  (42/75)   <- unusable, DO NOT act on it
--   UNCLEAR     27   --               (21 of the 27 are in fact Primary)
--
-- The asymmetry is structural, not a tuning artefact: explicit self-referential wording
-- ("the data underpinning the analysis reported in this paper") is real positive evidence of
-- primary deposit, but its ABSENCE is not evidence of reuse -- the same
-- absence-of-evidence-is-not-evidence-of-absence pattern as gen_evidence's no_metadata_yet
-- and as the DOI cascade's own residual branch. So use the PRIMARY verdict only; leave
-- SECONDARY and UNCLEAR as Unclassified.
--
-- Base-rate robustness. The 0.962 is measured where the gold population is 72% Primary, so it
-- cannot be transferred to the residue unchanged -- the mistake that invalidated an earlier
-- mixture estimate here. By likelihood ratio instead: P(says PRIMARY | Primary) = 0.581,
-- P(says PRIMARY | Secondary) = 0.059, so LR = 9.85. Precision then holds at 0.91 if the
-- residue is 50% Primary (which is what its own 26 gold-labelled rows measure), 0.84 at 35%,
-- and only breaks the 0.8 floor below about 30% Primary. Reasonably robust, but re-measure
-- against a labelled residual sample before trusting it in production.
--
-- TWO PROMPTS THAT FAILED, recorded so they are not retried. Both collapsed to a near-constant
-- SECONDARY predictor (31.7% and 30.3% accuracy; 268 of 303 rows SECONDARY):
--   v1 said "Do not guess from field conventions" -- which forbade the single inference that
--      makes these sentences decidable, since a data-availability statement IS the convention
--      by which authors cite their own data.
--   v2 said wording like "available from" a named archive implies SECONDARY -- actively wrong,
--      because "available from the Dryad Digital Repository" is the commonest PRIMARY phrasing.
-- The fix in v3 is to separate WHOSE data it is from WHERE it sits. The repository name carries
-- no signal; self-referential language carries all of it.
--
-- Cost to scale (Flash-Lite, extrapolated from the 623-row run):
--   all 313,033 residual rows        ~$25   -> ~23,645 PRIMARY verdicts
--   availability_only  (27,245)      ~$2.2  -> ~10,217   <- best return by far
--   + no_location_signal (34,182)    ~$2.7  ->  ~5,555
--   + availability_ref   (7,451)     ~$0.6  ->  ~1,770
--   reference_only     (244,155)     ~$19.5 ->  ~6,104   <- 40x worse per recovery; skip
-- The three small cells are 22% of the residue and yield 74% of the recoveries for ~$5.50.
--
-- RUN 2026-09-04 (approved): the three-cell version, 68,878 rows, 0 unparseable.
--   availability_only   27,245 ->  9,523 PRIMARY
--   no_location_signal  34,182 ->  5,052 PRIMARY
--   availability_ref     7,451 ->  1,764 PRIMARY
--   TOTAL               68,878 -> 16,339 PRIMARY   (projection said 17,542; 93% of it)
-- At the LR-corrected ~0.91 precision that is ~14,900 genuine Primary recoveries. Results are
-- in `${work_dataset}.llm_doi_primary_scores`. NOTHING CONSUMES THAT TABLE YET -- no stage
-- reads it and no type has been changed. Wiring it into a writeback needs the residual-sample
-- precision measurement first, because the 0.962 was measured on the gold population, not here.
--
-- Complementary to the stage-61 author-name fix, measured on the 320-row sample: of a 121-row
-- union, only 29 rows are flagged Primary by both. So the two recover largely different rows
-- (~24% overlap) and their yields are roughly additive. 43 sample rows are name-fix Primary but
-- LLM SECONDARY -- the most informative rows to review, since the two signals disagree.
--
-- Usage: set the cell filter to the strata being scored, then apply only the PRIMARY verdict.
CREATE OR REPLACE TABLE `${work_dataset}.llm_doi_primary_scores` AS
WITH resid AS (
  SELECT publication_id, dataset_doi, ds_title, pub_title,
         CASE WHEN in_availability AND NOT via_reference THEN 'availability_only'
              WHEN in_availability                       THEN 'availability_ref'
              WHEN via_reference                         THEN 'reference_only'
              ELSE 'no_location_signal' END AS cell
  FROM `${work_dataset}.doi_citations_typed`
  WHERE type = 'Unclassified'
    -- reference_only is 78% of the residue but yields 26% of the recoveries; excluded by
    -- default on cost. Widen deliberately, not by accident.
    AND NOT (via_reference AND NOT in_availability)
),
sent AS (
  -- one representative sentence per pair, preferring the most informative location
  SELECT publication_id, doi,
    ARRAY_AGG(STRUCT(location, text) ORDER BY
      CASE location WHEN 'availability_sentences' THEN 1
                    WHEN 'abstract_sentences'     THEN 2
                    WHEN 'body_sentences'         THEN 3
                    ELSE 4 END, LENGTH(text) DESC LIMIT 1)[OFFSET(0)] AS s
  FROM `${work_dataset}.datacite_sentence_matches_confirmed_remapped`
  GROUP BY 1, 2
)
SELECT r.publication_id, r.dataset_doi, r.cell,
       sn.s.location AS sentence_location, sn.s.text AS sentence,
       AI.GENERATE(prompt => CONCAT(
"""Decide whether the article containing this sentence GENERATED the dataset (PRIMARY) or REUSED data that already existed (SECONDARY).

The repository does NOT tell you. Dryad, Zenodo, figshare, Dataverse and institutional archives hold both kinds of data. "Available from the Dryad Digital Repository" is not evidence of reuse. Ignore where the data sits and ask only WHOSE data it is.

PRIMARY -- the sentence refers to the data as belonging to this piece of work. Self-referential wording is the signal: "the data supporting the findings of this study", "data underpinning the analysis reported in this paper", "our data", "data generated in this work", "we deposited", "data for the compounds described here". Authors almost never write "we generated this" -- they write "the data for this paper are available at X". Treat that as PRIMARY.
Also PRIMARY: a dataset title of the form "Data from: <title>" where that title matches or closely echoes the article title. That is the standard convention for a dataset deposited alongside its own paper.

SECONDARY -- the data is attributed to someone else or to a resource that existed before this work: "obtained from", "downloaded from", "we used data from [another study/group]", "provided by", or an established ongoing resource (a satellite mission, reference database, national survey, long-running consortium) that the article clearly did not create. Also SECONDARY when the dataset is cited the way a piece of literature is cited, in support of a claim about prior work.

UNCLEAR -- a bare identifier or URL with no surrounding wording, or prose that does not indicate ownership either way.
NOT_DATA -- the identifier is not a research dataset (software, a paper, a reagent catalogue number).

Reply with exactly one word: PRIMARY, SECONDARY, NOT_DATA or UNCLEAR.

Article title: """, IFNULL(r.pub_title, '(none)'),
         "\nDataset title: ", IFNULL(r.ds_title, '(none)'),
         "\nSentence location in article: ", sn.s.location,
         "\nSentence: ", sn.s.text),
         endpoint => 'gemini-2.5-flash-lite').result AS llm_raw
FROM resid r
JOIN sent sn ON sn.publication_id = r.publication_id AND sn.doi = r.dataset_doi;
