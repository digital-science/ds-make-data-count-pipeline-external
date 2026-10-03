# Pipeline stages

Stages run in numeric order. The runner discovers them by globbing `sql/NN_*.sql`, so the table below describes the directory, not a hard-coded sequence. Two stages have no file of their own: 42 (the DOI matching loop) and 51 (regex discovery, generated at run time from the `accession_families` patterns marked low false-positive risk). Both are run by the runner.

The monthly release runs at 06:00 UTC on the 2nd and is a full pass over the corpus each time.

## Runners

Two runners exist and produce the same result:

- **`scripts/run_pipeline.py`** — single process, blocking. Suits a workstation run or re-running one stage.
- **AWS Step Functions + Lambda** — runs the monthly refresh unattended. Stages too long for one 15-minute invocation (42's matching loop, the prefilter sweep) are split into checkpointed batches driven by the state machine. The SQL is identical.

## Stages

| Stage | What | Cost notes (on-demand, indicative) |
|---|---|---|
| `load_sources.py` | Europe PMC accession annotations + lexicons → work dataset (see [sources.md](sources.md) for the current state of the Europe PMC files) | load jobs are free |
| `prefilter.py` | DOI-prefix full-text search → `doi_candidates` (Dimensions Analytics API) | API subscription; ~2h20m wall-clock. **Rate-limited to ~2 calls/sec per API key — do not parallelise** |
| GenBank attribution fetch | Per-accession NCBI E-utilities fetches for cited nucleotide and protein records → `insdc_attribution`. Run by a separate fetcher, not included in this repository; stage 66 reads its output only when the `insdc_attribution_enabled` / `insdc_include_protein` gates in `tables.yaml` are TRUE | — |
| 10 | DataCite snapshot dedup (DOI universe) | pennies |
| 20 | Accession candidates (Europe PMC annotations joined to articles by PMCID, PMID fallback) | < $0.10 |
| 30 | Widened sweep candidate set | pennies |
| **31** | **Full-text join — scans the ENTIRE fulltext column** | **the expensive one; runner cost-caps it** |
| 32 | Sentence explosion (structured full text → location-labelled sentences incl. availability sections, table rows, reference titles/URIs) | few $ |
| 39 | Creates the empty accumulation table that stage 41 inserts into | free |
| 40–44 | DOI token extraction → batched snapshot matching (42, runner-internal loop, ~9h) → longest-match dedup → reference remapping | ~$5–10 total |
| 50–51 | Accession in-text verification and contexts; regex discovery (51, runner-internal) | ~$3 |
| 60–64 | DOI features + typing; accession typing; cue scoring + write-back | ~$2 |
| 65 | One-Primary-per-dataset uniqueness pass (demotes inference-based Primaries on all but the earliest citing paper) | pennies |
| 66–68 | Repository-metadata evidence tier: build evidence → apply → uniqueness. GenBank attribution comes from the E-utilities cache above plus a frozen GenBank flat-file mirror (`insdc_provenance`), kept as a fallback for records no longer returned by NCBI | ~$1.50 |
| 69 | Model tier — `ML.PREDICT` over the trained classifier | pennies |
| 70 | Unified `data_citations` view | pennies |
| 71 | LLM tier (DOI arm): applies cached PRIMARY verdicts to rows still Unclassified | pennies (inference itself is a separate, manual, paid step) |
| 72–76 | Reproducibility layer: rule, pattern and method registries (72); one row per citation with its deciding rule and tier (73); one row per mention, sentence text for open-access articles only (74); per-tier evidence tables (75); the release record with its benchmark scores (76) | — |
| 80–81 | Recall audit against DataCite relations (optional but recommended) | ~$1 |

## Ordering constraints not obvious from the numbers

- **65 must follow 61.** Stage 61 is `CREATE OR REPLACE`; 65 changes the table it produces. Re-running 61 alone silently discards 65's demotions and inflates Primary.
- **71 must follow 65**, so it only fills rows still Unclassified and its uniqueness guard sees the final set of Primaries. It is numbered after 70 because 70 is a *view* — a stored query — so later writes to the underlying table still show through it.
- `sql/manual/` sits outside the `NN_*.sql` glob on purpose. It holds steps that must never run automatically: classifier training, and the paid LLM inference that stage 71 consumes.

## Design rules

- Every stage is dry-run-estimated before execution; stage 31 aborts over the cost cap.
- A candidate ID only counts if the string is found in the article text (DOI: whitespace-stripped token matching; accession: exact case-sensitive match).
- Type assignment is cheapest-evidence-first: registered relations → metadata similarity → family priors → mention-context cues → repository-deposit evidence → model → LLM. Each tier only fills what the cheaper ones left Unclassified, so no tier can overwrite stronger evidence and every stage is idempotent on re-run.
- Thresholds are measured against labelled data where labels exist. A tier that cannot show ≥0.8 precision on the population it would decide ships those rows as Unclassified instead. `docs/methods.md` records the measurements, including the ones that failed.
- High-false-positive accession families (see the `fp_notes` in `lexicons/accession_patterns.json`) are excluded from regex discovery; format-invalid accessions are excluded from the product view.
