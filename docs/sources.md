# Data sources and licences

Every external input the pipeline uses beyond the Dimensions corpus, the terms it is available under, and the research notes behind choosing it. Companion file: `../lexicons/accession_patterns.json` (validated patterns per accession family).

- **Source licences** (next section) — what feeds the released data and on what terms. Start here.
- **Sections 1–4** — background research compiled 2026-08-11 while extending the DOI pipeline to accession IDs, following the top-5 Make Data Count Kaggle solutions (September 2025). Figures in those sections are as found at the time and are dated where it matters.

---

## Source licences (verified 2026-09-18)

Every input beyond the Dimensions corpus, with the licence as stated by the source. Checked against the policy pages linked; two are unresolved and flagged as such rather than assumed.

### Feed the shipped product

| Source | Licence as stated | Where |
|---|---|---|
| DataCite metadata | **CC0 1.0** — DataCite "waived all copyright and related or neighboring rights to DataCite Data File". Covers DataCite's aggregated metadata only, not the linked datasets; attribution requested as a community norm, not a condition. | [DataCite data file use policy](https://support.datacite.org/docs/datacite-data-file-use-policy) |
| Europe PMC text-mined accession annotations | **NOT STATED at the download location** — see the open item below, still open. Separately, the upstream files were empty (0 bytes) from before 4 September 2026 until **6 October 2026**, when Europe PMC republished (confirmed via a direct FTP listing: real file sizes, not 0 bytes). The 202610 release still ran on the stale last-good-copy (loaded 21 September); the next monthly run (2 November, release 202611) will pick up fresh annotations for the first time since this broke. | [FTP directory](https://ftp.ebi.ac.uk/pub/databases/pmc/TextMinedTerms/) · [EMBL-EBI terms](https://www.ebi.ac.uk/about/terms-of-use/) |
| GenBank / INSDC flat-file mirror (`insdc_provenance`; frozen, no longer refreshed — kept as a fallback for records NCBI no longer returns) | **Free and unrestricted** — "no restrictions or licensing fees will be placed on the redistribution or use of the database by any party". NCBI adds that it "places no restrictions on the use or distribution of the data" while noting submitters may assert rights in contributed content. | [INSDC policy](https://www.insdc.org/policy/) · [NCBI policies](https://www.ncbi.nlm.nih.gov/home/about/policies/) |
| NCBI SRA metadata (BigQuery public dataset) | As NCBI above. Also hosted as a Google Cloud public dataset, which carries its own terms page — check both. | [NCBI policies](https://www.ncbi.nlm.nih.gov/home/about/policies/) |
| NCBI E-utilities — GenBank nucleotide and protein records for cited accessions only (`insdc_attribution`), plus BioSample / BioProject / GEO | As NCBI above: GenBank/INSDC data are freely available without restriction on use or distribution. The separate E-utilities usage policy governs request rates, not licensing. This per-accession fetch replaced a daily GenBank flat-file mirror, now retired. | [NCBI policies](https://www.ncbi.nlm.nih.gov/home/about/policies/) |
| RCSB PDB (data API) | **CC0 1.0 Universal** — applies to all PDB archive files and all data served through the RCSB programmatic APIs. Attribution encouraged, not required. | [RCSB usage policy](https://www.rcsb.org/pages/usage-policy) |
| ENA browser API (EMBL flat files) | ENA is an INSDC member, so the INSDC free-and-unrestricted policy applies; EMBL-EBI places "no additional restrictions ... other than those provided by the original data owners" and expects attribution. | [INSDC policy](https://www.insdc.org/policy/) · [EMBL-EBI terms](https://www.ebi.ac.uk/about/terms-of-use/) |
| Google Vertex AI (Gemini 2.5 Flash-Lite) | Not a data source, but its **output ships in the product** as the `llm_primary` labels. Governed by Google Cloud service terms rather than a data licence. | — |

### Evaluation only — never shipped, but they produce the published precision figures

| Source | Licence as stated | Where |
|---|---|---|
| Kaggle competition training labels | **UNVERIFIED** — the rules page requires a logged-in session, so the licence could not be checked from here. | [Competition rules](https://www.kaggle.com/competitions/make-data-count-finding-data-references/rules) |
| rdmpage corrected labels | **CC0-1.0**, per the repository licence. | [GitHub](https://github.com/rdmpage/make-data-count-training-data) · [Kaggle mirror](https://www.kaggle.com/datasets/rdmpage/new-training-labels) |

### Assessed but NOT used

| Source | Licence | Note |
|---|---|---|
| MDC / DataCite Data Citation Corpus | **CC0 1.0** | Confirmed *not* referenced by any pipeline SQL or handler. It was assessed for quality (see the critiques in section 1) and not ingested. Public materials should not imply otherwise. |

### Open item

**Europe PMC annotations have no licence statement at the point of download.** The FTP directory carries only a `PRIVACY-NOTICE.txt` — no LICENSE, no README — and EMBL-EBI's general terms explicitly defer to "the original data owners", which for text-mined annotations means the contributing text-mining groups rather than EBI. Europe PMC's own site returns HTTP 403 to automated requests, so it could not be checked from here. This matters more than any other item on the page: these annotations seed the entire accession arm, which is 7,360,967 of the 8,751,192 citations (84%) in release 202610. Status at 2 October 2026: raised with Europe PMC, still open. Not a release blocker — the CC0 licence below ships with this item unresolved.

---

## 1. MDC / DataCite Data Citation Corpus

| Item | Value |
|---|---|
| Latest release | **v4.1** (published 2025-08-15) — no newer release found as of 2026-08-11 |
| Version DOI / URL | `10.5281/zenodo.16901115` — https://zenodo.org/records/16901115 |
| Concept DOI (always latest) | `10.5281/zenodo.11196858` |
| Files | `2025-08-15-data-citation-corpus-v4.1-csv.zip` (**887.5 MB**), `2025-08-15-data-citation-corpus-v4.1-json.zip` (**1.0 GB**). JSON is the version of record. Unzipped sizes: multiple GB (unverified exact figure). |
| Records | 10,697,745 citation records; 9,682,257 unique dataset–publication pairs |
| License | CC0 1.0 |
| Documentation | https://makedatacount.org/find-a-tool/data-citation-corpus-documentation/ |
| Release cadence so far | v1 Jan 2024, v2 Aug 2024, v3 Feb 2025, v4.0 Jul 2025, v4.1 Aug 2025 |

### Record schema (14 fields)

Required: `id` (internal UUID), `created`, `updated`, `publication` (article DOI), `dataset` (dataset DOI **or accession number**), `source`. Optional: `repository`, `publisher`, `journal`, `title`, `publishedDate`, `subjects`, `affiliations`, `funders`. Coverage of the optional metadata fields is patchy and varies by source.

### `source` field values

- `datacite` — DataCite Event Data (DOI-to-DOI links from metadata).
- `czi` — Chan Zuckerberg Initiative Science Knowledge Graph (NER/text-mined; the source Rod Page's criticism targets).
- `eupmc` — Europe PMC text-mining annotations, added in release 4.0 (~5.2 M citations ingested 2025-07-09).
- `asap` — Aligning Science Across Parkinson's.
- Whether any `czi`-sourced records remain in v4.x after the Europe PMC ingest, or were fully replaced: **unverified** — check the v4.1 release notes / a `source` group-by after load.

### Accession families documented as included

60+ life-science repositories, including: GEO, BioProject, BioSample, ArrayExpress, ENA/GenBank, GISAID (genomics); PDB, EMDB, EMPIAR, CATH (structures); UniProt, Ensembl, InterPro, Pfam, ChEMBL, BioModels, IntAct, Reactome (reference/functional databases); dbGaP, EGA, MetaboLights, PRIDE (clinical/omics); plus DOI-identified datasets. Note the corpus mixes deposition archives with reference-database entries — the latter are usually not "data citations" in the Dimensions sense.

### Rod Page's documented quality problems

Post 1 — "Problems with the DataCite Data Citation Corpus" (Feb 2024, on v1): https://doi.org/10.59350/t80g1-xys37 (iphylo.blogspot.com)

- Widespread NER false positives from the CZI text-mining: grant numbers (e.g. "Y21026"), museum specimen codes, mouse-line designations, and even time strings ("24hr") extracted as GenBank/PDB accessions.
- PDB: of ~1.7 M PDB citation records, ~31,600 (18%) failed basic format validation; of the rest only ~71% matched actual PDB holdings — over half a million apparently spurious citations.
- GenBank: in a 1,000-accession sample, 486 (48.6%) were unknown to GenBank.
- Single-article example: a ZooKeys paper credited with 126 data citations had zero legitimate ones (the "PDB IDs" were figure labels).
- Structural gripes: UUID bloat (7 GB JSON), thin documentation, no repository-level view in the dashboard, no validation of extracted IDs against the source repositories.

Post 2 — "The Data Citation Corpus revisited" (Oct 2024, on v2): https://doi.org/10.59350/wvwva-v7125

- Quality problems persist in v2; "anyone basing metrics upon this corpus would need to proceed very carefully."
- Top "most-cited datasets" are false matches to non-data entities: `LY294002` (a PI3K-inhibitor compound, 9,983 "citations"), `A549` (a cell line, 5,883).
- Repository-name inconsistencies (e.g. "Figshare" vs "figshare"; Taylor & Francis as a branded Figshare) frustrate aggregation.
- Many "citations" are just publication→own-supplementary-material links (e.g. Informa journals auto-depositing supplements to Figshare), i.e. availability, not reuse; the long tail is overwhelmingly single-citation records.

**Pipeline implication:** treat `czi`-sourced records as untrusted until format-validated (our regexes) *and* existence-checked against the source repository; prefer `eupmc`- and `datacite`-sourced records.

### Load-to-BigQuery notes

- CSV zip unpacks to one or more large CSVs: `bq load --source_format=CSV --skip_leading_rows=1 --allow_quoted_newlines` (titles contain newlines/commas). Exact internal file layout of the v4.1 zips: unverified until downloaded.
- JSON (version of record) is standard JSON, not NDJSON — convert with `jq -c '.[]'` per file before `bq load --source_format=NEWLINE_DELIMITED_JSON`, or land in GCS and use an external table over the converted files.
- `subjects` / `affiliations` / `funders` are nested — load as `JSON` type columns (simplest) or REPEATED RECORDs.
- Partition/cluster suggestion: cluster on `source` and `repository`; the first-pass QC query is a `source` × `repository` count plus regex-validity rate per accession family.

---

## 2. Europe PMC Text-Mined Terms (bulk accession annotations)

**URL:** https://europepmc.org/pub/databases/pmc/TextMinedTerms/ (same path on the EBI FTP: `ftp.ebi.ac.uk/pub/databases/pmc/TextMinedTerms/`)

### Layout and format

> **Current status (7 October 2026):** the upstream files were empty (0 bytes) from before 4 September 2026 until 6 October 2026, when Europe PMC republished with real content (confirmed via a direct FTP directory listing — not downloaded, per data-usage constraints at the time of checking). The 202610 release still ran on the stale last-good-copy (loaded 21 September); the next monthly run (2 November, release 202611) will pick up fresh annotations. The directory still carries no licence statement (see the open item under Source licences) — that is unaffected by the republish and remains open with Europe PMC. The description below is as found in August 2026.

Flat directory: **one CSV per database/accession family** (55 files as of 2026-08-10 refresh) plus `PRIVACY-NOTICE.txt`. Most files regenerated 2026-08-10; at the time they appeared to refresh regularly (roughly weekly/monthly cadence — unverified).

Format (verified by sampling `geo.csv`, `metabolights.csv`, `gen.csv`): 4 columns, header row, accession values double-quoted:

```
geo,PMCID,EXTID,SOURCE
"GSE37569",PMC4410982,25977790,MED
```

- Col 1: the accession (header is the family name, e.g. `geo`).
- `PMCID`: Europe PMC / PMC identifier of the article.
- `EXTID`: external ID — the PMID when `SOURCE=MED`; other SOURCE values (e.g. `PMC`, `PPR` preprints) key to other ID spaces.
- `SOURCE`: article ID namespace.
- One row per (accession, article) annotation; keying to articles is via PMCID and/or EXTID+SOURCE.

### Files relevant to our accession families (sizes from directory listing, 2026-08-10)

| File | Size | Family |
|---|---|---|
| `geo.csv` | 18 M | GEO (GSE/GSM/GPL/GDS) |
| `gen.csv` | 138 M | ENA/GenBank/DDBJ nucleotide+protein accessions (verified: contains AF..., AAN... IDs). Whether SRA run/experiment IDs (SRR/ERR/DRR) are in this file or elsewhere: **unverified — no dedicated `sra.csv` exists; spot-check before relying** |
| `bioproject.csv` | 4.2 M | PRJNA/PRJEB/PRJDB |
| `biosample.csv` | 775 K | SAMN/SAMEA/SAMD |
| `refseq.csv` | 22 M | RefSeq |
| `pdb.csv` | 28 M | PDB |
| `uniprot.csv` | 24 M | UniProt |
| `ensembl.csv` | 4.8 M | Ensembl |
| `arrayexpress.csv` | 601 K | E-MTAB etc. |
| `pxd.csv` | 830 K | PRIDE |
| `metabolights.csv` | 35 K | MTBLS |
| `chembl.csv` | 211 K | ChEMBL |
| `interpro.csv` | 723 K | InterPro |
| `pfam.csv` | 1.9 M | Pfam |
| `dbgap.csv` | 327 K | phs |
| `emdb.csv` | 406 K | EMD- |
| `empiar.csv` | 49 K | EMPIAR- |
| `cellosaurus.csv` | 1.6 M | CVCL_ |
| `refsnp.csv` | 40 M | dbSNP rs (FP-prone — see §3) |
| `gisaid.csv` | 1.3 M | EPI_ISL |
| `gca.csv` | 2.5 M | GCA_ assemblies (excluded family) |
| `ega.csv` | 246 K | EGA (excluded by 1st place) |

Other files present (context / excluded families): `doi.csv` (421 M), `nct.csv` (52 M), `rrid.csv` (40 M), `go.csv` (16 M), `omim.csv` (8.9 M), `hgnc.csv` (289 K), `treefam.csv` (8.2 K), `eudract.csv` (654 K), `ebisc.csv` (112 K), `hipsci.csv` (8.3 K), `alphafold.csv` (24 K), plus biomodels, biostudies, brenda, cath (0 bytes), chebi, complexportal, efo, gwas, hpa, hPSCreg, igsr, intact, metagenomics, mint, orphadata, reactome, rfam, rhea, rnacentral, uniparc, bia.

### Load-to-BigQuery notes

- Small enough to load whole: total for our families is well under 1 GB. `bq load --source_format=CSV --skip_leading_rows=1` with schema `accession:STRING, pmcid:STRING, ext_id:STRING, source:STRING`; header column names differ per file, so supply an explicit schema and skip the header.
- Add a `family` column at load time (derive from filename) and union into one table clustered on `family, accession`.
- Join to Dimensions publications via PMCID (primary) with PMID (`EXTID` where `SOURCE='MED'`) as fallback.

### Alternative: Europe PMC Annotations API

- Base: `https://www.ebi.ac.uk/europepmc/annotations_api/` — docs at https://europepmc.org/AnnotationsApi
- `GET annotationsByArticleIds?articleIds=MED:25977790&type=Accession%20Numbers&format=JSON` — returns per-article annotations with `exact` (matched string), `prefix`/`postfix` (context snippets — useful features for primary/secondary classification), `subType` (database, e.g. `GEO`), `section` (e.g. Methods), and an identifiers.org URI.
- `subType` parameter filters to one database when `type=Accession Numbers` or `Resources`.
- **Batch limit: 1–8 article IDs per request** (verified empirically — a 9-ID request returns HTTP 400: "The articleIds list parameter must contain between 1 and 8 values").
- Also `annotationsByEntity` and `annotationsByProvider` (paged) endpoints for corpus-style sweeps.
- Rate limits: no numeric rate limit is published (**unverified**); EBI fair-use applies. For our scale, use the bulk TextMinedTerms CSVs and reserve the API for enrichment (section + context snippets).

---

## 3. Accession families the Kaggle winners EXCLUDED (false-positive-prone)

Excluded by multiple top-5 solutions:

- `GCA_*` / `GCF_*` genome assemblies — almost always reference-genome *reuse*, not primary data.
- `HGNC:*` — gene nomenclature, not data.
- `GO:*` — ontology terms, not data.
- `RRID:*` — research resources (antibodies, cell lines, software), not datasets.
- dbSNP `rs*` — variant references; excluded in some solutions (kept with heavy filtering in others).
- Unfiltered ENA/GenBank letter+digit accessions — the highest-FP family (grant numbers, specimen codes); winners required context cues or validation.

Additionally excluded by the 1st-place team:

- EGA (`EGAS*/EGAD*`), AlphaFold (`AF-*`), TreeFam (`TF*`), EudraCT trial numbers, OMIM, EBiSC, HipSci.

These map onto `fp_risk`/`fp_notes` in `accession_patterns.json`; the corresponding Europe PMC files exist (see table above) if we later want them as negative/secondary evidence rather than dropping them outright.

---

## Regex sourcing notes (see `accession_patterns.json`)

- Primary source: identifiers.org registry API — `https://registry.api.identifiers.org/restApi/namespaces/search/findByPrefix?prefix=<ns>` (note: rapid-fire requests get throttled; add ~1.5 s delays).
- Where the registry pattern was defective or looser, the JSON uses a stricter form and records the difference in `source`: UniProt (registry pattern contains literal commas/spaces in character classes), Ensembl (registry has a match-anything final alternative), ArrayExpress (restricted to E-* experiments), PRIDE (dropped RPXD), MetaboLights (dropped MTBLC compounds), dbGaP (escaped dots), Cellosaurus (dropped a stray `(\.txt)?`), SRA (minimum 6 digits).
- GISAID, TCIA and Dryad have no usable identifiers.org namespace (GISAID/TCIA lookups returned empty); patterns are conventional and marked as such. TCIA and Dryad are DOI-prefix families (10.7937, 10.5061) and should route through the existing DOI pipeline.
- Every regex was machine-verified against positive and negative examples before writing.

---

## 4. Public BigQuery equivalents for repository metadata (catalogue)

Prefer SQL joins over API pagination wherever a public BigQuery dataset covers the need. Surveyed August 2026; re-verify freshness before relying on any of these.

| Resource | BigQuery location | Carries | Verdict for this pipeline |
|---|---|---|---|
| **NCBI SRA metadata** | `nih-sra-datastore.sra.metadata` (43.7M runs) | run/sample/biosample/bioproject linkage, submitting centre, release dates | **ADOPTED** — replaces API calls for SRA/BioSample/BioProject/SRS enrichment (dates + org + project consistency); org names need affiliation-matching, author names still need the API record |
| DataCite | `ds-open-datasets.datacite.records` (ORION-DBs; weekly-refreshed current table — `records_2024`/`records_2025` are frozen annual snapshots, not what the pipeline reads) | full registry incl. relatedIdentifiers, creators, clients | ADOPTED throughout |
| ChEMBL | `bigquery-public-data.ebi_chembl` | full ChEMBL universe | existence checks for discovery QC (reference DB — secondary prior regardless) |
| Open Targets | `open-targets-prod.platform` (52 tables) | Ensembl target universe (fresh), drug molecules, 175M Europe PMC publication↔entity links | existence checks (Ensembl); `literature_entity_lut` is a sibling entity-mention resource, not an input |
| MGnify, AlphaFold, gnomAD | `bigquery-public-data.ebi_mgnify` / `deepmind_alphafold` / `gnomAD` | reference universes | no action (families excluded or secondary-prior) |
| ISB-CGC genome reference | `isb-cgc.genome_reference` | GENCODE/Ensembl/dbSNP(638M rs)/UniProt-idmapping/InterPro/miRBase universes | **caution: snapshots frozen ~2016–2018** — existence checks would false-fail newer IDs; prefer Open Targets / ebi_chembl where fresher |
| GDC / cancer programs | `isb-cgc-bq.*` (94 datasets) | TCGA/GDC case & file metadata | not deposition provenance; no action |
| **No BigQuery equivalent found** | — | GenBank/ENA nucleotide submission records (submitters, dates, linked pubs); PDB deposition records; GEO series metadata; GISAID | API fetchers remain: ENA EMBL flat format (batch-tolerant), RCSB GraphQL, NCBI E-utilities; GISAID has no open route |

---

## Changelog

- **2026-10-07** — Europe PMC's upstream TextMinedTerms files, empty since before 4 September, were confirmed republished with real content as of 6 October (direct FTP listing, not downloaded). The 202610 release ran on the stale last-good-copy regardless; 202611 (2 November) is the first release that will read fresh data. The licence-statement gap at the download location is unaffected and remains open.
- **2026-09-27** — Licence table moved to the top. GenBank attribution now comes from per-accession NCBI E-utilities fetches (cited nucleotide and protein records) plus the frozen flat-file mirror; the daily mirror is retired. Europe PMC status recorded: upstream files empty since before 4 September, no licence statement at the download location, both open.

- **2026-09-04** — The `SRA` family pattern was extended to accept run/experiment/study/sample accessions of the `[SED]R[APRSXZ]\d{6,}` shape (ERR/SRR/DRR runs, ERX/SRX experiments, ERP/SRP studies, and so on). The previous pattern matched only a subset, and every accession it missed was silently dropped before typing — recovering them added ~144k citations. Worth noting as a general hazard with this dossier: a pattern that is too narrow fails *silently*, since a non-matching accession is indistinguishable from an accession that was never text-mined. Format-validity rates quoted above are therefore a floor, not a measurement of mining quality.
- **2026-08** — Section 4 added (public BigQuery equivalents); `nih-sra-datastore.sra.metadata` adopted in place of API pagination for SRA/BioSample/BioProject enrichment.
