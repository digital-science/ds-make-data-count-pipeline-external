-- Cue-lexicon scoring of mention sentences; |score| >= 2 resolves a pair, else falls through to the model tier
CREATE OR REPLACE TABLE `${work_dataset}.accession_cue_scores` AS
WITH row_scores AS (
  SELECT ctx.publication_id, ctx.accession, ctx.family, ctx.location, ctx.sentence,
         IFNULL((SELECT SUM(CASE WHEN cue.direction = 'primary' THEN cue.weight ELSE -cue.weight END)
                 FROM `${work_dataset}.classification_cues` cue
                 WHERE REGEXP_CONTAINS(ctx.sentence, cue.pattern)), 0)
         + CASE WHEN ctx.location IN ('availability_sentences','availability_titles') THEN 1.0
                WHEN STARTS_WITH(ctx.location, 'references') THEN -1.0
                ELSE 0 END AS row_score,
         (SELECT STRING_AGG(cue.cue_id, ',')
          FROM `${work_dataset}.classification_cues` cue
          WHERE REGEXP_CONTAINS(ctx.sentence, cue.pattern)) AS cues_hit
  FROM `${work_dataset}.accession_contexts` ctx
)
SELECT publication_id, accession, family,
       SUM(row_score) AS score,
       COUNT(*) AS n_mentions,
       STRING_AGG(cues_hit, ',') AS all_cues,
       CASE WHEN SUM(row_score) >= 2  THEN 'Primary'
            WHEN SUM(row_score) <= -2 THEN 'Secondary'
            ELSE 'Unresolved' END AS cue_type
FROM row_scores
GROUP BY 1, 2, 3
