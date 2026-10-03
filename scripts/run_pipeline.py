#!/usr/bin/env python3
"""Pipeline runner: renders sql/ templates against tables.yaml and executes them in order.

Usage:
  python scripts/run_pipeline.py --list                 # show stages
  python scripts/run_pipeline.py --stage 60 --dry-run   # cost-estimate one stage
  python scripts/run_pipeline.py --all --execute        # run everything (cost-gated)

Every stage is dry-run-estimated before execution. Stage 31 (the full-text join) scans the
entire fulltext column of your ${fulltext_publications} table regardless of candidate count —
the runner aborts if its estimate exceeds --cost-cap (default $60) unless --yes is passed.
"""
import argparse, glob, os, re, sys, time
from string import Template

import yaml
from google.cloud import bigquery

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRICE_PER_TB = 6.25  # USD, on-demand list price; adjust for your billing model


def load_config():
    path = os.path.join(HERE, 'tables.yaml')
    if not os.path.exists(path):
        sys.exit('tables.yaml not found - copy tables.example.yaml and fill in your tables')
    cfg = yaml.safe_load(open(path))
    cfg.setdefault('project', cfg['work_dataset'].split('.')[0])
    return cfg


def render(sql_path, cfg):
    return Template(open(sql_path).read()).safe_substitute(cfg)


def stages():
    return sorted(glob.glob(os.path.join(HERE, 'sql', '*.sql')))


def estimate(client, sql):
    job = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
    return job.total_bytes_processed / 1e12 * PRICE_PER_TB


def run_matching_loop(client, cfg, batch_size=5_000_000):
    """Stage 42: iterate the matching procedure over the DOI snapshot in batches."""
    ds = cfg['work_dataset']
    total = list(client.query(
        f'SELECT COUNT(*) n FROM `{ds}.datacitesnapshot_no_igsnarxiv_r`').result())[0].n
    offset = 0
    while offset < total:
        print(f'  match batch {offset + 1:,}..{min(offset + batch_size, total):,} of {total:,}', flush=True)
        client.query(f'CALL `{ds}.process_dois_by_batch`({offset + 1}, {offset + batch_size})').result()
        offset += batch_size


def run_discovery(client, cfg):
    """Stage 51: regex discovery for low-FP families; generated from accession_families."""
    ds = cfg['work_dataset']
    fams = client.query(
        f"SELECT family, pattern FROM `{ds}.accession_families` "
        "WHERE fp_risk = 'low' AND pattern IS NOT NULL").to_dataframe()
    arms = []
    for _, r in fams.iterrows():
        # non-capturing groups: REGEXP_EXTRACT_ALL allows <=1 group and returns the group, not the match
        pat = re.sub(r'\((?!\?)', '(?:', r.pattern.lstrip('^').rstrip('$'))
        arms.append(f"SELECT publication_id, '{r.family}' family, acc, location "
                    f"FROM `{ds}.sweep_sentences`, UNNEST(REGEXP_EXTRACT_ALL(text, r'{pat}')) acc")
    sql = (f"CREATE OR REPLACE TABLE `{ds}.accession_discovered` CLUSTER BY family, accession AS "
           "SELECT DISTINCT publication_id, family, acc accession, location FROM (\n"
           + "\nUNION ALL\n".join(arms) + ")")
    return sql


SPECIAL = {'42': run_matching_loop, '51': run_discovery}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--stage', help='two-digit stage prefix, e.g. 31')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--execute', action='store_true', help='actually run (default: dry-run only)')
    ap.add_argument('--cost-cap', type=float, default=60.0)
    ap.add_argument('--yes', action='store_true', help='override the cost cap')
    args = ap.parse_args()

    files = stages()
    if args.list:
        for f in files:
            print(' ', os.path.basename(f))
        print('  (42: matching loop and 51: discovery are runner-internal stages)')
        return

    cfg = load_config()
    client = bigquery.Client(project=cfg['project'])
    selected = [f for f in files if not args.stage or os.path.basename(f).startswith(args.stage)]

    for f in selected:
        name = os.path.basename(f)
        sql = render(f, cfg)
        usd = estimate(client, sql)
        print(f'[{name}] dry-run ~${usd:.2f}', flush=True)
        if not args.execute:
            continue
        if usd > args.cost_cap and not args.yes:
            sys.exit(f'[{name}] ${usd:.2f} exceeds cap ${args.cost_cap}; re-run with --yes to proceed')
        t0 = time.time()
        client.query(sql).result()
        print(f'[{name}] done in {(time.time() - t0) / 60:.1f} min', flush=True)
        # runner-internal follow-ons
        if name.startswith('41') and (args.all or args.stage == '41'):
            print('[42 matching loop] starting (multi-hour)', flush=True)
            run_matching_loop(client, cfg)
        if name.startswith('50') and args.all:
            sql = run_discovery(client, cfg)
            print(f'[51 discovery] dry-run ~${estimate(client, sql):.2f}', flush=True)
            client.query(sql).result()
            print('[51 discovery] done', flush=True)


if __name__ == '__main__':
    main()
