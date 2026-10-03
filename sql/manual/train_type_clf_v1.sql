-- Train the type classifier. DELIBERATELY OUTSIDE the numbered stage sequence.
--
-- The runner discovers stages by globbing `sql/NN_*.sql`, so nothing in this subdirectory is
-- picked up by a pipeline run. That is the point: an unguarded monthly retrain is a
-- silent-quality risk. The labels this trains on are themselves produced upstream (the repo
-- evidence tier), so each cycle would shift the training set, and a model that quietly got
-- worse would still ship its predictions -- exactly what the standing precision-floor rule
-- exists to prevent. Retrain as a deliberate act, then check ML.EVALUATE against the recorded
-- baseline (val precision 0.935 Primary / 0.974 Secondary) BEFORE letting 69 score with it.
--
-- Ported verbatim from R1 (job of 2026-08-14T12:37:43, r1-recovered-sql/model_queries m_00).
-- Substitute ${...} by hand, or run through the stage runner's renderer.
--
-- Note what is excluded from the feature list: identifiers (they would let the tree memorise
-- individual pairs), the outcome columns (type, rule_applied -- the label's own source), and
-- sample_weight / eval_grade_label / split (bookkeeping, not signal). `eval_grade_label` in the
-- WHERE clause restricts training to repository-evidence labels only, i.e. the 0.97-1.00
-- precision tier -- never the cue or LLM labels.

CREATE OR REPLACE MODEL `${type_model}`
OPTIONS (
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['label'],
  max_iterations = 60,
  early_stop = TRUE,
  enable_global_explain = TRUE
) AS
SELECT * EXCEPT (publication_id, accession, type, rule_applied, sample_weight,
                 eval_grade_label, split)
FROM `${work_dataset}.model_features`
WHERE split = 'train' AND label IS NOT NULL AND eval_grade_label;

-- Gate before use:
--   SELECT * FROM ML.EVALUATE(MODEL `${type_model}`, (
--     SELECT * EXCEPT (publication_id, accession, type, rule_applied, sample_weight,
--                      eval_grade_label, split)
--     FROM `${work_dataset}.model_features`
--     WHERE split = 'val' AND label IS NOT NULL AND eval_grade_label));
--   SELECT feature, ROUND(attribution, 3) a
--   FROM ML.GLOBAL_EXPLAIN(MODEL `${type_model}`) ORDER BY a DESC;
