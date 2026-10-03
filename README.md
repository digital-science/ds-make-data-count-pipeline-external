# Open Data Citations pipeline (experimental)

This repository holds the code that builds the Open Data Citations dataset: links from scholarly articles to the datasets they cite, found by text-mining full text for dataset DOIs and repository accession IDs (GenBank, PDB, UniProt, GEO and others). Each link is classified as **Primary** (data generated for the citing article), **Secondary** (data reused) or left **Unclassified** where the evidence is not strong enough. The methods follow the top solutions of the [Make Data Count Kaggle competition](https://www.kaggle.com/competitions/make-data-count-finding-data-references).

Powered by Dimensions, the pipeline has been built by Digital Science research staff in collaboration with Make Data Count. The public dataset is available on BigQuery via [ORION-DBs](https://orion-dbs.community/).

## What it produces

A new release each month (06:00 UTC on the 2nd), rebuilt from a full pass over the corpus. The pipeline writes three layers: private working tables (intermediate stages and the classifier, not released) and two public ones:

- **Released data** — one row per (article, dataset) citation, in six columns: article DOI, dataset id (a DOI or an accession id), which kind of id it is, the repository, the citation type (Primary / Secondary / Unclassified) and the release. Keyed from both ends, so it can be joined by article or by dataset. Citations from articles without a DOI are not included.
- **Reproducibility layer** — for every citation: which rule decided it, that rule's definition and measured precision, where in the article each mention sits, the models and prompts used, and the release's own benchmark scores. Mention sentence text is included for open-access articles only.

Release 202610 (October 2026): 8,751,192 citations from 2,081,909 articles to 4,508,541 distinct datasets; 92.14% classified. Against two community gold sets combined (1,061 article-dataset pairs) it agrees on 0.9616 of the pairs it classifies and classifies 0.9076 of them. [docs/methods.md](docs/methods.md) explains how, and what the benchmark does not cover.

## Running it

All table references are logical. Copy `tables.example.yaml` to `tables.yaml` (gitignored) and point it at your own tables. Load the external sources (`scripts/load_sources.py`) and build the DOI candidate list (`scripts/prefilter.py`) first, then:

```
python scripts/run_pipeline.py --list                 # show stages
python scripts/run_pipeline.py --all                  # dry-run cost estimate for every stage
python scripts/run_pipeline.py --all --execute        # run (cost-capped)
```

The full pipeline needs structured full text; the classification, lexicon and audit stages run against any input in the same shape. [docs/pipeline.md](docs/pipeline.md) gives the stage order and costs.

## Repository layout

- `sql/` — pipeline stages, `NN_name.sql`, run in numeric order
- `lexicons/` — `cue_lexicon.json` (deposition/reuse cues), `accession_patterns.json` (validated per-family patterns with false-positive notes)
- `scripts/` — runner, source loader, prefilter, and `check_no_internal_refs.sh` (CI guard)
- `examples/` — worked queries (e.g. funder data flow) and a notebook tracing one citation through the reproducibility layer
- `docs/` — [methods.md](docs/methods.md) (every stage and table schema), [pipeline.md](docs/pipeline.md) (run order and costs), [sources.md](docs/sources.md) (external data sources and their licences)

## Licensing

Code: MIT (see LICENSE). Dataset: **CC0**. The release publishes citation assertions derived from its inputs, not the inputs themselves; the inputs and their own terms are documented in [docs/sources.md](docs/sources.md) — one source (Europe PMC) has no licence statement at its download location — noted, not resolved, before this release.
