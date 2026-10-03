-- SRAD mentions: one row per mention OCCURRENCE, not per citation. A dataset mentioned in three
-- sentences gets three rows, because that is what tracing a decision requires.
--
-- THE OPEN-ACCESS GATE LIVES HERE AND NOWHERE ELSE. `sentence` is NULL unless the citing article
-- is open access. One gate in one column is auditable; the same rule spread across several tables
-- is not, and no other SRAD table carries sentence text (evidence_llm deliberately references
-- this table rather than duplicating the string). Measured 2026-09-22: 95.1% of citations and
-- 86.4% of articles are open access, so the gate costs little coverage -- the DOI arm depends on
-- full text we hold, which skews the corpus open.
--
-- `sentence_is_withheld` distinguishes "no sentence because closed access" from "no sentence
-- because no mention was found". Those support opposite conclusions, and without the flag a
-- researcher cannot tell them apart.
--
-- `location` is always populated. `original_location` is DOI-arm only and non-null when the
-- identifier was printed in the bibliography and stage 44 relocated the match to the in-text
-- sentence that cites that reference -- the distinction between "the article printed this DOI in
-- its own prose" and "the article cited a reference that carries this DOI", which matters for
-- interpreting a primary/secondary call.
CREATE OR REPLACE TABLE `${srad_dataset}.mentions`
PARTITION BY release_date
CLUSTER BY publication_id, dataset_id AS
WITH rel AS (
  SELECT FORMAT_DATE('%Y%m', CURRENT_DATE()) AS release,
         DATE_TRUNC(CURRENT_DATE(), MONTH)   AS release_date
),
oa AS (
  SELECT id AS publication_id, 'oa_all' IN UNNEST(open_access_categories_v2) AS is_oa
  FROM `${publications_metadata}`
),
-- Accession-arm mentions: stage 50 writes one row per (accession, sentence) where the accession
-- string was found by exact case-sensitive match.
acc AS (
  SELECT publication_id, accession AS dataset_id, 'accession' AS id_kind,
         location, CAST(NULL AS STRING) AS original_location, sentence
  FROM `${work_dataset}.accession_contexts`
),
-- DOI-arm mentions: post-confirmation and post-reference-remapping, so `location` is where the
-- mention is attributed and `original_location` is where the string was physically found.
doi AS (
  SELECT publication_id, doi AS dataset_id, 'doi' AS id_kind,
         location, original_location, text AS sentence
  FROM `${work_dataset}.datacite_sentence_matches_confirmed_remapped`
),
unioned AS (
  SELECT * FROM acc UNION ALL SELECT * FROM doi
),
-- Restrict to mentions of identifiers that actually reached the product. A mention of a candidate
-- that failed verification is pipeline state, not evidence behind a published decision, and
-- SRAD_DESIGN.md excludes it on purpose.
kept AS (
  SELECT u.*
  FROM unioned u
  JOIN (SELECT DISTINCT publication_id, dataset_id FROM `${work_dataset}.data_citations`) c
    USING (publication_id, dataset_id)
)
SELECT
  rel.release,
  rel.release_date,
  k.publication_id,
  k.dataset_id,
  k.id_kind,
  ROW_NUMBER() OVER (
    PARTITION BY k.publication_id, k.dataset_id
    -- Deterministic: availability statements first, then abstract, body, everything else, then
    -- longest sentence. Stable across releases so a cited mention_ordinal keeps its meaning.
    ORDER BY CASE k.location
               WHEN 'availability_sentences' THEN 1
               WHEN 'availability_titles'    THEN 2
               WHEN 'abstract_sentences'     THEN 3
               WHEN 'body_sentences'         THEN 4
               ELSE 5 END,
             LENGTH(IFNULL(k.sentence, '')) DESC,
             k.location
  ) AS mention_ordinal,
  k.location,
  k.original_location,
  IF(IFNULL(oa.is_oa, FALSE), k.sentence, NULL) AS sentence,
  NOT IFNULL(oa.is_oa, FALSE) AS sentence_is_withheld,
  IFNULL(oa.is_oa, FALSE) AS is_open_access
FROM kept k
LEFT JOIN oa USING (publication_id)
CROSS JOIN rel;
