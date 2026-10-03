-- Accession regex QC + conservative typing (competition-validated rules; reference-DB priors; residual left Unclassified)
CREATE OR REPLACE TABLE `${work_dataset}.accession_citations_typed`
CLUSTER BY family, accession AS
-- pdb notation collisions. The pdb pattern (digit + 3 alphanumerics, fp_risk 'high') is satisfied
-- by two notations that are not structure citations, and existence checks cannot catch either:
-- '7q22', '9q13', '2Fuc', '3Gal' are all real PDB entries, the collision is in the text. Both
-- rules read the mentions stage 50 captured, so a pair with no mention is never excluded here.
--   band_notation   chromosome bands ('chromosome 8p11', '19q13.2', '7q22.1'). Bands are written
--                   with lowercase p/q, real PDB ids in text almost always uppercase; the few
--                   lowercase real ones ('PDB code 4q20') carry a PDB cue, which exempts the pair.
--                   Sampled 2026-09-25: 25/25 bands where the id sat inside a longer band string,
--                   23/30 confirmed non-data and 0/30 real structures where it did not (the other
--                   7 bare table cells); 15/15 cue-exempted pairs were real structures.
--   glycan_notation monosaccharide residues in linkage notation ('Galα1-3Gal', 'GlcNAcβ1-2Man').
--                   Matched case-sensitively on the residue spelling, so a real citation written
--                   '2FUC' is unaffected. Sampled 45/45 glycan notation, including every pair with
--                   a PDB cue -- those are structural-biology papers, so no cue exemption.
-- A plain character-boundary rule was measured and rejected: SWISS-MODEL template notation
-- ('3k92.1.A'), chain suffixes ('1lobA') and extended ids ('pdb_00006r49') break the boundary on
-- genuine citations, and ~75% of non-band pairs it flagged were real.
WITH pdb_notation AS (
  SELECT publication_id, accession,
         LOGICAL_OR(REGEXP_CONTAINS(LOWER(sentence), r'pdb|protein data bank')) AS any_pdb_cue
  FROM `${work_dataset}.accession_contexts`
  WHERE family = 'pdb'
    AND (REGEXP_CONTAINS(accession, r'^[0-9][pq][0-9]{2}$')
         OR REGEXP_CONTAINS(accession, r'^[0-9](Fuc|Gal|Glc|Man|Xyl|Neu|Sia|Rha|Ara|Hex|Kdo)$'))
  GROUP BY 1, 2),
notation AS (
  SELECT publication_id, accession, 'pdb' AS family,
         CASE WHEN REGEXP_CONTAINS(accession, r'^[0-9](Fuc|Gal|Glc|Man|Xyl|Neu|Sia|Rha|Ara|Hex|Kdo)$')
                THEN 'glycan_notation'
              WHEN NOT any_pdb_cue THEN 'band_notation' END AS notation_rule
  FROM pdb_notation)
SELECT c.* EXCEPT (notation_rule), f.fp_risk, f.default_type_prior,
  CASE WHEN f.pattern IS NULL THEN NULL
       ELSE REGEXP_CONTAINS(c.accession, f.pattern) END AS regex_valid,
  CASE
    WHEN f.pattern IS NOT NULL AND NOT REGEXP_CONTAINS(c.accession, f.pattern)
                                             THEN 'Excluded'      -- format-invalid
    WHEN c.notation_rule IS NOT NULL         THEN 'Excluded'      -- not a structure id in context
    WHEN c.family IN ('biosample','emdb')    THEN 'Primary'       -- Kaggle-validated rules
    WHEN f.default_type_prior = 'secondary-leaning'
                                             THEN 'Secondary'
    ELSE 'Unclassified'                                            -- mixed/primary-leaning: needs context
  END AS type,
  CASE
    WHEN f.pattern IS NOT NULL AND NOT REGEXP_CONTAINS(c.accession, f.pattern)
                                             THEN 'regex_invalid'
    WHEN c.notation_rule IS NOT NULL         THEN c.notation_rule
    WHEN c.family = 'biosample'              THEN 'kaggle_samn_rule'
    WHEN c.family = 'emdb'                   THEN 'kaggle_emdb_rule'
    WHEN f.default_type_prior = 'secondary-leaning'
                                             THEN 'reference_db_prior'
    ELSE 'residual'
  END AS rule_applied
FROM (
  SELECT a.*, n.notation_rule
  FROM `${work_dataset}.accession_candidates` a
  LEFT JOIN notation n USING (publication_id, accession, family)
) c
LEFT JOIN `${work_dataset}.accession_families` f USING (family)
WHERE c.publication_id IS NOT NULL
