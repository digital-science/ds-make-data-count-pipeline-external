-- Reference remapping: bibliography-only DOI hits relocated to the in-text sentences citing them (via structured-fulltext refids)
CREATE OR REPLACE TABLE `${work_dataset}.datacite_sentence_matches_confirmed_remapped` AS
WITH refs AS (
  SELECT g.id publication_id, ref.id refid, ref.article_id.doi
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.bibliography.references) ref
  WHERE ref.article_id.doi IS NOT NULL),
text_sections AS (
  SELECT g.id publication_id, 'body_sentences' location, s.text, s.citations
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.body.sections) sect, UNNEST(sect.sentences) s
  UNION ALL
  SELECT g.id, 'availability_sentences', s.text, s.citations
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.availability.sections) sect, UNNEST(sect.sentences) s
  UNION ALL
  SELECT g.id, 'abstract_sentences', s.text, s.citations
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.abstract.sections) sect, UNNEST(sect.sentences) s
  UNION ALL
  SELECT g.id, 'annex_sentences', s.text, s.citations
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.annex.sections) sect, UNNEST(sect.sentences) s
  UNION ALL
  SELECT g.id, 'notes_sentences', s.text, s.citations
  FROM `${work_dataset}.sweep_grobid` g, UNNEST(fulltext.notes) n, UNNEST(n.sentences) s),
reference_location AS (
  SELECT ts.publication_id, ts.location, ts.text, ref.doi
  FROM text_sections ts, UNNEST(citations) c
  INNER JOIN refs ref ON ts.publication_id = ref.publication_id AND c.refid = ref.refid
  INNER JOIN `${work_dataset}.datacite_sentence_matches_confirmed` smc
     ON smc.publication_id = ts.publication_id AND smc.location = 'references_titles'
    AND LOWER(ref.doi) = LOWER(smc.doi))
SELECT DISTINCT smc.publication_id,
       IFNULL(rl.location, smc.location) location,
       smc.location original_location,
       IFNULL(rl.text, smc.text) text,
       smc.doi
FROM `${work_dataset}.datacite_sentence_matches_confirmed` smc
LEFT JOIN reference_location rl
  ON rl.publication_id = smc.publication_id AND LOWER(rl.doi) = LOWER(smc.doi)
 AND smc.location = 'references_titles'
