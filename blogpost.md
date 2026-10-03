# What a Kaggle competition taught us about finding data citations — and what we're doing about it

Data citations link research papers to the datasets they create or reuse. They remain one of the most under-recorded links in the scholarly record. In 2025 the [Make Data Count](https://makedatacount.org/) initiative ran a [Kaggle competition](https://www.kaggle.com/competitions/make-data-count-finding-data-references) in which more than 1,200 teams worked to find dataset references in scientific full text. Each reference had to be classified as **Primary** (data generated for that paper) or **Secondary** (data reused from elsewhere). The five winning solutions are, in effect, independently developed and well-tested blueprints for the problem.

This note reviews those five solutions, reports an audit of the Dimensions extraction pipeline against their lessons, and describes how we rebuilt it taking findings from all five.

## What the winners actually did

The competition had an additional challenge. Its "ground truth" labels were not hand-annotated; they were derived from machine sources — Europe PMC's text-mined accession numbers and DataCite's dataset-to-article links. The teams that noticed stopped trying to out-extract the labellers and **looked the answers up in the same corpora the labels came from**, keeping only IDs that appeared in each article's text. The 1st-place team ([write-up](https://www.kaggle.com/competitions/make-data-count-finding-data-references/writeups/1st-place-solution)) built their whole candidate stage this way. The 5th-place solo entrant titled their write-up "[by standing on the shoulders of Giants](https://www.kaggle.com/c/make-data-count-finding-data-references/writeups/5th-place-by-standing-on-the-shoulders-of-giants)" for the same reason.

That is a competition artefact, but it encodes a real-world truth: **know the provenance of your ground truth before you optimise against it.**

Beyond the twist, the five solutions converged on a remarkably consistent architecture:

1. **Two stages everywhere.** Find candidate dataset mentions (dataset DOIs plus accession IDs such as `GSE30611` or `SAMN14299293`), then classify each mention's type. No winner collapsed these into one model.

2. **Verification discipline.** A candidate only counts if the ID string actually appears in the article text. Every team applied this filter, and it did more for precision than any model.

3. **Accession IDs are the majority of data use.** Roughly 70% of dataset mentions were accession IDs and 30% dataset DOIs. A DOI-only pipeline misses most of the picture.

4. **DOI classification doesn't need an LLM.** The 1st-place team's strongest component was a CatBoost model over *metadata similarity*: does the dataset's title, author list or year resemble the citing article's? Their LLM attempts at the same subtask lost to it. The 2nd-place team went further and showed that **rules alone** — "dataset registered as `IsSupplementTo` this article → Primary", "dataset cited by many papers → earliest is Primary, rest Secondary", "SAMN/EMDB → Primary" — scored at a level that would have won a gold medal with no model at all.

5. **LLMs earn their keep where context matters.** For accession IDs, the type signal lives in the sentence: "sequences were *deposited* under…" versus "data were *downloaded* from…". Winners used zero-shot Qwen-class models on context snippets, with two cost disciplines worth copying. Cascade from small to large models, escalating only uncertain cases (4th place). And mine the structured XML for the *right* context — the table row containing the ID, the data-availability statement — rather than a blind character window (5th place).

6. **Know your false-positive families.** GCA\_ genome assemblies, HGNC/GO/RRID ontology-style identifiers, dbSNP rs-numbers, and unfiltered GenBank-style letter+digit codes (which collide with grant numbers and specimen codes) burned every team that kept them unfiltered.

## What we changed at Dimensions

Full-text GROBID representations of tens of millions of articles in BigQuery, plus the Dimensions Analytics API's full-text search, let us apply the winners' results at corpus scale. The API search decides *which* articles are worth the expensive full-text scan: we search it for every DataCite DOI prefix and only scan the candidate articles that come back.

The winners' biggest lesson — *measure recall against external ground truth before trusting your extraction* — is where we started.

**The audit.** We benchmarked the pipeline against 4.25 million dataset→article links asserted in DataCite's own metadata. The pipeline recovered only a small fraction — until the per-repository breakdown told the real story. Most registered links come from publisher workflows that register DOIs for supplementary material at scale, hosted by repositories such as figshare. The supplement belongs to the article, so its DOI *rarely appears in the article's own text*; its absence is not an extraction failure. For genuine data repositories, candidate recall ran at 78–94% (Dryad 78%, USGS 84%, UCAR 85%, GigaDB 94%). Our string matcher proved nearly loss-free: of sampled misses where we held the text, only \~1% actually contained the DOI.

**Whitespace handling.** Printed DOIs often contain a line-break space (`10. 1594/pangaea.967352`, with a space after the `10.`, is a common typesetting artefact). Allowing for it in search and matching recovered roughly 9% of otherwise-missed candidate articles at high-recall repositories.

**The reframe.** The audit's deepest lesson mirrors the competition: **registered relations and in-text mentions are different populations of evidence.** Repositories assert links that articles never print, and vice versa. We treat them as complementary evidence, each flagged by provenance, rather than one as ground truth for the other.

**Classification, mostly without an LLM.** Following the 1st- and 2nd-place recipes, we classified matched DOI citations with rules plus metadata similarity. An independent check supports the features: pairs DataCite registers as supplements to the article (near-certain Primary) show author overlap of 0.80, against a 0.28 background. Rules alone classified 77%, so the cheap tier carries three-quarters of the work. The remaining fifth did eventually need a model reading sentences — as a last tier over a small residue, not as the architecture (see below).

**The accession side.** We loaded Europe PMC's text-mined accession annotations (7.5 million) and the Data Citation Corpus v4.1 (10.7 million records). As Rod Page's [critiques](https://doi.org/10.59350/t80g1-xys37) warned and our checks confirmed, 4 million records from its noisiest source need validation before use. Joined to Dimensions by PMCID, the Europe PMC annotations yielded **7.4 million accession–article pairs across 1.18 million articles** — almost exactly the 70/30 split the competition predicted. Europe PMC's mining proved clean (99.6–100% format-valid for most families), so our first version relied on provenance, with conservative typing: Primary only where a competition-validated rule exists, Secondary for reference databases, and an honest **Unclassified** for deposition archives that need context.

**GenBank records and PDB identifiers.** For GenBank sequences, the pipeline fetches each cited record directly from NCBI, nucleotide and protein alike, and reads its attribution: who submitted it, and which publications it links. Those decide the citation type. Protein records follow the same rules with one guard: a citing article that shares an author with the genome project's publication, and appeared within a year of the deposit, stays Unclassified rather than being called reuse (520 citations).

PDB identifiers need a different check. Chromosome-band notation ("7q22.1", "19q13.2") and glycan notation ("Galα1-3Gal") contain strings that are valid PDB IDs, so a format check cannot catch them. The pipeline reads the surrounding text instead and excludes about 12,100 such mentions.

**Where that leaves us.** The latest release (October 2026) holds **8.75 million data citations across 2.08 million articles and 4.5 million distinct datasets**. 92% are classified Primary or Secondary. The public release gives each citation's article, dataset, repository and classification. A reproducibility layer (accesible via the Digital Science SRAD program,) records which rule decided each citation, that rule's definition and measured precision, and where in the article the mention sits — plus the sentence itself for open-access articles.

## How it measures up

Comparing a production system with a competition leaderboard needs care. Scored the competition's way — F1 over (article, dataset, type) triples — our pipeline lands in the **mid-0.5s against the official competition labels**, well below the winners' 0.70–0.80. Most of our "false positives" against those labels turn out to be real citations the labels missed: the labels were machine-derived and incomplete, and the winners partly optimised toward their blind spots.

We therefore report two plainer measures against two gold sets. *Agreement* is the share of gold pairs we classify where our label matches. *Coverage* is the share of gold pairs we classify at all. Each article–dataset pair counts once.

| gold set | pairs | agreement | coverage |
| --- | --- | --- | --- |
| Kaggle competition labels | 463 | 0.951 | 0.786 |
| Community-corrected labels | 1,056 | 0.959 | 0.910 |
| Both combined | 1,061 | 0.962 | 0.908 |

Where we give a label, it matches both label sets about equally often; the difference is coverage. The two gold sets disagree with each other on 33 shared pairs, which are dropped from the combined score — so agreement of about 0.96 is close to the practical ceiling.

The benchmark has one blind spot we should state plainly. The gold sets contain almost none of the GenBank protein citations and few GenBank nucleotide ones, so GenBank citations decided from repository records rest on rule-level evidence, published in the reproducibility layer, rather than on the benchmark.

Our coverage of any label set is capped by two deliberate choices a competition doesn't reward. We only cover articles whose full text we hold, and we refuse to guess: the 687,407 citations we cannot decide ship as Unclassified rather than as a coin-flip. A leaderboard penalises silence; a production dataset earns trust with it.

Classification ended up dominated not by machine learning but by something better: **repository evidence**. For millions of pairs, the deposit record itself — its submitting authors, its date, the publication it links — settles primary versus secondary at 0.97–1.00 measured precision. That is why the pipeline fetches that evidence for every cited GenBank record, proteins included.

Where cheaper evidence ran out, we did use a language model, and the shape of that result is the most transferable thing here. The dataset-DOI citations that defeated every rule each carry a matched mention sentence; the features simply could not read it. A model reading that sentence identifies Primary deposits at **0.94 precision**, measured on 63 citations we labelled by hand.

The half we discard is the instructive half. The same model's *Secondary* verdicts scored 0.56, so they are never written. Explicit wording — "the data underpinning the analysis reported in this paper" — is real evidence that data was generated for the paper. The *absence* of such wording is not evidence of reuse. That asymmetry recurred everywhere, and our rule is simple: a tier that cannot show 0.8 precision **on the population it would actually decide** ships as Unclassified. Two candidate improvements failed that test in one afternoon — one a bug fix that looked plainly correct and would have written several thousand wrong classifications. Our benchmarks caught neither, because each changed tens of thousands of production rows but only a handful of benchmark rows. Hand-labelling a few hundred citations was the only check that could have caught either, and it is the cheapest tool we have.

## Known limitations — and one fix, already validated

Data-availability statements — where data citations most often sit — are fairly new, and older GROBID models trained on earlier papers often miss the section entirely. Among articles our search index flagged but where we found no citation, roughly half of the externally checkable cases have an availability statement in the publisher's XML that extraction missed. We measured the fix before claiming it. Re-extracting a 150-article sample with the latest GROBID recovered **88% of the confirmed losses**, with no regression on sections already captured. It also made **half of the high-value misses from our recall audit visible** — misses we had put down to citations simply not being in the text. The extraction upgrade is the single highest-yield improvement on the roadmap, and the re-check sample is saved so the fix can be verified once output from the new Grobid model is available.

Other limitations we publish alongside the data:

- **Europe PMC text-mined terms.** The upstream files have been empty since before 4 September. The release uses the last good copy (loaded 21 September), so annotations for five accession families are stale. There is also no licence statement at the download location. Both are open with Europe PMC.
- **GenBank residue.** 332,092 GenBank citations remain Unclassified. About 242,000 accessions sit in records with neither submitters nor a publication link — largely EST, GSS and patent records from the 1990s and 2000s. No source we can reach holds their attribution.
- **Dataset DOIs.** 282,312 DOI citations (20%) remain Unclassified, mostly reference-list mentions with no location signal. This should improve with the GROBID upgrade described above: recovering the availability statements older models miss gives many of these mentions the location they lack.

## What's next

The pipeline is built, benchmarked and runs unattended. A monthly refresh on AWS Lambda and Step Functions starts at 06:00 UTC on the 2nd of each month and re-sweeps the full corpus in about nine hours. The next release is due on 2 November 2026. What follows is release engineering and community:

1. **A public dataset** — every data citation from an article with a DOI, in six plain columns: the article's DOI, the dataset's DOI or accession id, which of the two it is, the repository, the citation type (Primary, Secondary or Unclassified) and the release. It can be joined from either end: by article, or by dataset. It is on BigQuery via the community-run ORION-DBs catalogue and refreshed monthly, released under a CC0 licence. The full research-grade dataset, including how each citation was decided and the sentences behind it, is available to scientometrics researchers through Digital Science's SRAD programme.
2. **A community gold set instead of a private one.** The release publishes measured precision per rule, the independently adjudicated seed cases, and an open adjudication route. We invite the community that already corrected the competition's labels once to build the benchmark this field lacks. Contributed labels feed the next release's *measured* precision.
3. **The sequence provenance layer** — attribution for cited GenBank records, fetched from NCBI, and the evidence behind our highest-precision tier. It could be offered publicly if there is community demand.
4. **The extraction upgrade** described above, then a re-sweep that runs the whole pipeline unchanged over better text.
5. **Contribution to the Data Citation Corpus** — a `dimensions` source with per-family precision attached, closing the loop with the Make Data Count initiative that started this.

---

*With thanks to the competition teams whose generous write-ups made this possible — particularly Kea Kohv & Ali (1st), NikhilMishra & Mohsin Hasan (2nd), matheus & Eduardo Rocha de Andrade (3rd), Ahmet Erdem, Raja Biswas & David Austin (4th), and cm391 (5th) — and to Rod Page, whose public data-quality critiques were as valuable as any solution.*
