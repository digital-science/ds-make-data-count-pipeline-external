-- SRAD release anchor. This is what makes a pinned release citable: without the pipeline commit
-- and the measured benchmark, "release 202610" names a table rather than a method.
--
-- Appends rather than replaces, and clears any existing row for this release first, so a re-run
-- supersedes instead of duplicating -- one row per release is the invariant. Same pattern and
-- same reasoning as snapshot_release's changelog handling.
--
-- Benchmark figures are computed here rather than copied from a document, so they cannot drift
-- from the release they describe. They are deduped to distinct (article, dataset) pairs and
-- exclude pairs the two gold sets label differently, because tie-breaking those would be
-- inventing ground truth. `gold_pairs_discordant` counts the discordant pairs THAT REACHED THE
-- PRODUCT, so it is smaller than the raw gold-set figure (33 vs 69 at release 202609, of 634
-- pairs present in both sets). Either way it is a ceiling worth publishing: on those pairs no
-- classifier can agree with both sets at once.

CREATE TABLE IF NOT EXISTS `${srad_dataset}.releases` (
  release               STRING,
  release_date          DATE,
  created_at            TIMESTAMP,
  citations             INT64,
  articles              INT64,
  datasets              INT64,
  pct_classified        FLOAT64,
  pct_open_access       FLOAT64,
  agreement_kaggle      FLOAT64,
  coverage_kaggle       FLOAT64,
  agreement_rdmpage     FLOAT64,
  coverage_rdmpage      FLOAT64,
  gold_pairs_discordant INT64,
  pipeline_commit       STRING,
  notes                 STRING,
  -- Both gold sets together: each (article, dataset) pair counted once, pairs the two sets
  -- label differently dropped rather than tie-broken. This is the headline figure; it is
  -- computed here, from the released data, so no document has to run a separate script.
  -- Same method as aws/bench_product.sh's "BOTH (distinct, concordant)" row.
  agreement_combined    FLOAT64,
  coverage_combined     FLOAT64,
  gold_pairs_combined   INT64
);
-- Columns added after the first release; positional INSERT below relies on this order.
ALTER TABLE `${srad_dataset}.releases` ADD COLUMN IF NOT EXISTS agreement_combined FLOAT64;
ALTER TABLE `${srad_dataset}.releases` ADD COLUMN IF NOT EXISTS coverage_combined FLOAT64;
ALTER TABLE `${srad_dataset}.releases` ADD COLUMN IF NOT EXISTS gold_pairs_combined INT64;

DELETE FROM `${srad_dataset}.releases`
WHERE release = FORMAT_DATE('%Y%m', CURRENT_DATE());

INSERT INTO `${srad_dataset}.releases`
WITH gold AS (
  SELECT 'kaggle' src, REGEXP_REPLACE(article_id, r'^([0-9.]+)_', r'\1/') a,
         LOWER(REGEXP_REPLACE(dataset_id, r'^https?://(dx\.)?doi\.org/', '')) d1,
         dataset_id raw_id, type
  FROM `${work_dataset}.kaggle_train_labels` WHERE type != 'Missing'
  UNION ALL
  SELECT 'rdmpage', REGEXP_REPLACE(article_id, r'^([0-9.]+)_', r'\1/'),
         LOWER(REGEXP_REPLACE(dataset_id, r'^https?://(dx\.)?doi\.org/', '')), dataset_id, type
  FROM `${work_dataset}.rdmpage_labels` WHERE type != 'Missing'
),
raw AS (
  SELECT g.src, v.publication_id, v.dataset_id, g.type AS bt, v.type AS ot
  FROM gold g
  JOIN `${publications_metadata}` p ON LOWER(p.doi) = LOWER(g.a)
  JOIN `${work_dataset}.data_citations` v ON v.publication_id = p.id
   AND (LOWER(v.dataset_id) = g.d1 OR v.dataset_id = g.raw_id
        OR UPPER(v.dataset_id) = UPPER(g.raw_id))
  WHERE v.type != 'Excluded'
),
per_src AS (
  SELECT src, publication_id, dataset_id, ANY_VALUE(bt) bt, ANY_VALUE(ot) ot
  FROM raw GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    MAX(IF(src='kaggle',  agreement, NULL)) AS agreement_kaggle,
    MAX(IF(src='kaggle',  coverage,  NULL)) AS coverage_kaggle,
    MAX(IF(src='rdmpage', agreement, NULL)) AS agreement_rdmpage,
    MAX(IF(src='rdmpage', coverage,  NULL)) AS coverage_rdmpage
  FROM (
    SELECT src,
           ROUND(COUNTIF(ot=bt)/COUNTIF(ot IN ('Primary','Secondary')), 4) AS agreement,
           ROUND(COUNTIF(ot IN ('Primary','Secondary'))/COUNT(*), 4)       AS coverage
    FROM per_src GROUP BY src)
),
discordant AS (
  SELECT COUNTIF(n > 1) AS n_disc
  FROM (SELECT publication_id, dataset_id, COUNT(DISTINCT bt) n FROM raw GROUP BY 1, 2)
),
combined AS (
  SELECT ROUND(COUNTIF(ot = bt) / COUNTIF(ot IN ('Primary','Secondary')), 4) AS agreement,
         ROUND(COUNTIF(ot IN ('Primary','Secondary')) / COUNT(*), 4)       AS coverage,
         COUNT(*) AS pairs
  FROM (SELECT publication_id, dataset_id, ANY_VALUE(ot) ot, ANY_VALUE(bt) bt,
               COUNT(DISTINCT bt) n_labels
        FROM raw GROUP BY 1, 2)
  WHERE n_labels = 1
),
product AS (
  SELECT COUNT(*) citations,
         COUNT(DISTINCT publication_id) articles,
         COUNT(DISTINCT dataset_id) datasets,
         ROUND(100*COUNTIF(type IN ('Primary','Secondary'))/COUNT(*), 2) pct_classified,
         ROUND(100*COUNTIF(is_open_access)/COUNT(*), 2) pct_open_access
  FROM `${srad_dataset}.citations`
  WHERE release = FORMAT_DATE('%Y%m', CURRENT_DATE())
)
SELECT
  FORMAT_DATE('%Y%m', CURRENT_DATE()),
  DATE_TRUNC(CURRENT_DATE(), MONTH),
  CURRENT_TIMESTAMP(),
  product.citations, product.articles, product.datasets,
  product.pct_classified, product.pct_open_access,
  scored.agreement_kaggle, scored.coverage_kaggle,
  scored.agreement_rdmpage, scored.coverage_rdmpage,
  discordant.n_disc,
  CAST(NULL AS STRING),   -- pipeline_commit: set by the caller, see notes below
  CONCAT('Sentence text exposed for open-access articles only. ',
         'Rule definitions in srad.rules; classifying methods in srad.methods. ',
         'Known limitations for this release are recorded in the project release notes.'),
  combined.agreement, combined.coverage, combined.pairs
FROM product, scored, discordant, combined;
