-- Cue write-back: only overwrites Unclassified rows; rule/prior assignments are never touched
UPDATE `${work_dataset}.accession_citations_typed` t
SET t.type = s.cue_type,
    t.rule_applied = CONCAT('cue_', LOWER(s.cue_type))
FROM `${work_dataset}.accession_cue_scores` s
WHERE t.publication_id = s.publication_id AND t.accession = s.accession
  AND t.type = 'Unclassified' AND s.cue_type != 'Unresolved'
