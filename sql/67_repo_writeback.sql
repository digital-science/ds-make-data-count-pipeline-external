-- Repository-evidence tier, part 2 of 3: apply the decisions to accession_citations_typed.
--
-- Both statements are dedup-guarded: an accession can have several evidence rows (multiple
-- provenance sources, or several lake records for one accession), and an UPDATE ... FROM with
-- more than one match per target row fails in BigQuery. Collapsing to one row per
-- (publication_id, accession) with ANY_VALUE(... HAVING MIN decision) is R1's fix, and MIN over
-- the decision *string* is what makes it deterministic. That is alphabetical order, not
-- precision order -- author_date_primary sorts first -- which is preserved deliberately: it is
-- what produced the 3.3M labelled decisions this port is validated against.
--
-- These rules intentionally OVERWRITE earlier, lower-precision decisions (cue and prior rules).
-- That is the point of the tier: in R1 it demoted 28k former Primaries, matching the direction
-- the 123 adjudicated cases pointed. Excluded rows are never touched.

-- Non-gen families (biosample / bioproject / metagenomics, and SRA-style gen accessions).
UPDATE `${work_dataset}.accession_citations_typed` t
SET type = CASE WHEN d.decision2 IN ('linked_pub_primary','author_date_primary',
                                     'org_date_primary','project_of_primary')
                THEN 'Primary' ELSE 'Secondary' END,
    rule_applied = CONCAT('repo_', d.decision2)
FROM (
  SELECT publication_id, accession,
         ANY_VALUE(decision2 HAVING MIN decision2) decision2
  FROM `${work_dataset}.repo_evidence2`
  WHERE decision2 != 'undecided'
  GROUP BY 1, 2
) d
WHERE t.publication_id = d.publication_id AND t.accession = d.accession
  AND t.type != 'Excluded';
-- NOTE on the Primary set above: R1's non-gen write-back listed only org_date_primary,
-- project_of_primary and linked_pub_primary, omitting author_date_primary -- which would have
-- written type='Secondary' under rule_applied='repo_author_date_primary'. It never bit, because
-- non-gen submitters are organisations (center_name), so the surname-overlap branch that yields
-- author_date_primary effectively cannot fire on these families -- which is precisely why the
-- org_date rule exists. Verified against the R1 product: all 414,139 repo_author_date_primary
-- rows are Primary, with no type/rule mismatch anywhere in the tier. The omission is corrected
-- here rather than reproduced; the validation diff confirms it changes nothing.

-- gen family via the provenance lake. 'no_metadata_yet' is excluded alongside 'undecided':
-- absence from the lake is recorded as evidence in the table but must not overwrite a decision.
UPDATE `${work_dataset}.accession_citations_typed` t
SET type = CASE WHEN d.decision IN ('linked_pub_primary','author_date_primary')
                THEN 'Primary' ELSE 'Secondary' END,
    rule_applied = CONCAT('repo_', d.decision)
FROM (
  SELECT publication_id, accession,
         ANY_VALUE(decision HAVING MIN decision) decision
  FROM `${work_dataset}.gen_evidence`
  -- held_protein_companion is a deliberate non-decision (stage 66's protein guard): excluded
  -- here, it would otherwise fall into the ELSE branch above and be written as Secondary.
  WHERE decision NOT IN ('undecided','no_metadata_yet','held_protein_companion')
  GROUP BY 1, 2
) d
WHERE t.publication_id = d.publication_id AND t.accession = d.accession
  AND t.type != 'Excluded'
