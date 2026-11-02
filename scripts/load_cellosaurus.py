#!/usr/bin/env python3
"""Load the Cellosaurus reference lists into ${work_dataset}.cellosaurus_refs.

Cellosaurus (https://www.cellosaurus.org, CC BY 4.0) records, for every cell line, the
publications that describe it. Stage 66 uses that list as source evidence: a citing paper is
called Primary for a cell line only if the line's own record says this paper first described it.

    python scripts/load_cellosaurus.py              # download both files and (re)load the table
    python scripts/load_cellosaurus.py --dry-run    # parse and report only, load nothing

One row per (cell line, reference): accession (CVCL_xxxx), cell_line, pmid, doi, ref_year. References
with no PubMed id (patents, datasheets, DOI-only) are loaded too, with ref_year NULL.
The table is replaced on every run. The monthly `load_sources` Lambda does this itself
(from 202611); run this script by hand only to load a scratch dataset or outside the pipeline.
`ref_year` is the publication year in Cellosaurus's own citation; it is NULL if not parseable,
and stage 66 treats a line with any NULL year as undecidable rather than guessing.
"""
import argparse
import os
import re
import urllib.request
from collections import defaultdict


BASE = "https://ftp.expasy.org/databases/cellosaurus"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fetch_lines(name):
    with urllib.request.urlopen(f"{BASE}/{name}", timeout=300) as resp:
        for raw in resp:
            yield raw.decode("utf-8", errors="replace").rstrip("\n")


def parse_refs():
    """pubmed id -> (doi, year) from cellosaurus_refs.txt."""
    ref, cur = {}, None
    for line in fetch_lines("cellosaurus_refs.txt"):
        if line.startswith("RX   "):
            pm = re.search(r"PubMed=(\d+)", line)
            doi = re.search(r"DOI=([^;\s]+)", line)
            cur = pm.group(1) if pm else None
            if cur:
                ref[cur] = {"doi": doi.group(1).lower() if doi else None, "year": None}
        elif line.startswith("RL   ") and cur:
            years = re.findall(r"\((\d{4})\)", line)
            if years:
                ref[cur]["year"] = int(years[-1])
        elif line.startswith("//"):
            cur = None
    return ref


def parse_entries(ref):
    rows, ac, name = [], None, None
    seen = defaultdict(set)
    for line in fetch_lines("cellosaurus.txt"):
        if line.startswith("ID   "):
            name = line[5:].strip()
        elif line.startswith("AC   "):
            ac = line[5:].strip().split(";")[0]
        elif line.startswith("RX   ") and ac:
            pm = re.search(r"PubMed=(\d+)", line)
            if pm:
                if pm.group(1) not in seen[ac]:
                    seen[ac].add(pm.group(1))
                    r = ref.get(pm.group(1), {})
                    rows.append({"accession": ac, "cell_line": name, "pmid": pm.group(1),
                                 "doi": r.get("doi"), "ref_year": r.get("year")})
            else:
                # Patents, datasheets (CelloPub) and DOI-only references carry no year here. They
                # are kept as year-less rows so stage 66 sees that the line has a reference it
                # cannot date, and therefore cannot claim any paper was first.
                doi = re.search(r"DOI=([^;\s]+)", line)
                rows.append({"accession": ac, "cell_line": name, "pmid": None,
                             "doi": doi.group(1).lower() if doi else None, "ref_year": None})
        elif line.startswith("//"):
            ac = None
    return rows


SCHEMA_FIELDS = (("accession", "STRING"), ("cell_line", "STRING"), ("pmid", "STRING"),
                 ("doi", "STRING"), ("ref_year", "INTEGER"))


def load_rows(client, rows, table):
    """Replace `table` (project.dataset.table) with `rows`. Shared with the load_sources Lambda."""
    from google.cloud import bigquery
    schema = [bigquery.SchemaField(n, t) for n, t in SCHEMA_FIELDS]
    client.load_table_from_json(
        rows, table,
        job_config=bigquery.LoadJobConfig(schema=schema, write_disposition="WRITE_TRUNCATE")).result()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--dataset", help="target dataset, project.dataset (default: work_dataset in tables.yaml)")
    args = ap.parse_args()
    ref = parse_refs()
    rows = parse_entries(ref)
    lines = len({r["accession"] for r in rows})
    print(f"{len(rows):,} (cell line, reference) rows across {lines:,} cell lines; "
          f"{sum(1 for r in rows if r['ref_year'] is None):,} without a year")
    if args.dry_run:
        return
    import yaml
    from google.cloud import bigquery
    cfg = {} if args.dataset else yaml.safe_load(open(os.path.join(HERE, "tables.yaml")))
    ds = args.dataset or cfg["work_dataset"]
    client = bigquery.Client(project=cfg.get("project", ds.split(".")[0]))
    load_rows(client, rows, f"{ds}.cellosaurus_refs")
    print(f"loaded {ds}.cellosaurus_refs")


if __name__ == "__main__":
    main()
