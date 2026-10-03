-- Repository-evidence tier, part 3 of 3: uniqueness passes.
--
-- A dataset can have only one originating article. Where a repo rule made the SAME accession
-- Primary for several articles, only the earliest publication keeps Primary; the rest are
-- demoted to Secondary under a `_not_first` rule, which preserves the audit trail (you can see
-- both that the evidence matched and why it was overridden).
--
-- The title guard is the subtle part: two publication_ids with identical normalised titles are
-- the same paper under two records (preprint/version duplicates), so demoting one against the
-- other would be wrong. Those are left alone.
--
-- Ordering is `year IS NULL, year, publication_id` -- missing years sort last, and the
-- publication_id tiebreak keeps the choice deterministic across re-runs.
--
-- Applies to the two rules that can plausibly fire for multiple articles. linked_pub_primary
-- needs no pass (it is already anchored to one specific article) and project_of_primary
-- inherits its uniqueness from the samples it is derived from.

-- repo_org_date_primary
UPDATE `${work_dataset}.accession_citations_typed` t
SET type = 'Secondary', rule_applied = 'repo_org_date_primary_not_first'
FROM (
  WITH prim AS (
    SELECT DISTINCT t.publication_id, t.accession, t.family, p.year,
           REGEXP_REPLACE(LOWER(IFNULL(p.title.preferred,'')), r'[^a-z0-9]', '') norm_title
    FROM `${work_dataset}.accession_citations_typed` t
    JOIN `${publications_metadata}` p ON p.id = t.publication_id
    WHERE t.type = 'Primary' AND t.rule_applied = 'repo_org_date_primary'),
  ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY family, accession
               ORDER BY year IS NULL, year, publication_id) rn FROM prim),
  earliest AS (SELECT family, accession, norm_title FROM ranked WHERE rn = 1)
  SELECT DISTINCT r.publication_id, r.accession, r.family
  FROM ranked r JOIN earliest e USING (family, accession)
  WHERE r.rn > 1 AND NOT (r.norm_title = e.norm_title AND r.norm_title != '')) d
WHERE t.publication_id = d.publication_id AND t.accession = d.accession
  AND t.family = d.family AND t.type = 'Primary';

-- repo_author_date_primary
UPDATE `${work_dataset}.accession_citations_typed` t
SET type = 'Secondary', rule_applied = 'repo_author_date_primary_not_first'
FROM (
  WITH prim AS (
    SELECT DISTINCT t.publication_id, t.accession, t.family, p.year,
           REGEXP_REPLACE(LOWER(IFNULL(p.title.preferred,'')), r'[^a-z0-9]', '') norm_title
    FROM `${work_dataset}.accession_citations_typed` t
    JOIN `${publications_metadata}` p ON p.id = t.publication_id
    WHERE t.type = 'Primary' AND t.rule_applied = 'repo_author_date_primary'),
  ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY family, accession
               ORDER BY year IS NULL, year, publication_id) rn FROM prim),
  earliest AS (SELECT family, accession, norm_title FROM ranked WHERE rn = 1)
  SELECT DISTINCT r.publication_id, r.accession, r.family
  FROM ranked r JOIN earliest e USING (family, accession)
  WHERE r.rn > 1 AND NOT (r.norm_title = e.norm_title AND r.norm_title != '')) d
WHERE t.publication_id = d.publication_id AND t.accession = d.accession
  AND t.family = d.family AND t.type = 'Primary'
