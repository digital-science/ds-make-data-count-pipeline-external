#!/usr/bin/env python3
"""Candidate prefilter: full-text search for DataCite DOI prefixes via the Dimensions
Analytics API (requires a Dimensions subscription; dimcli config in ~/.dimensions/dsl.ini).

For each DOI prefix the search includes BOTH the intact form (10.1594) and a phrase-quoted
line-broken variant ("10. 1594"): PDFs sometimes break a DOI after "10." and the full-text
index tokenizes the broken form so the intact-form search cannot match it. In our validation
this recovered ~9% of otherwise-missed articles at high-recall repositories.

Checkpoints each batch to ./prefilter_ckpt/ so restarts never repeat completed batches.
Output: ${work_dataset}.doi_candidates (one column: id).
"""
import os, sys, time, warnings
warnings.filterwarnings('ignore')
import pandas as pd
import yaml
import dimcli
from google.cloud import bigquery

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CKPT = os.path.join(HERE, 'prefilter_ckpt')
os.makedirs(CKPT, exist_ok=True)
N_BATCHES = 200
YEARS = (2015, 2026)  # adjust to your coverage window

cfg = yaml.safe_load(open(os.path.join(HERE, 'tables.yaml')))
client = bigquery.Client(project=cfg.get('project', cfg['work_dataset'].split('.')[0]))
dimcli.login()
dsl = dimcli.Dsl(verbose=False)

prefixes = client.query(f"""
    SELECT SPLIT(id,'/')[SAFE_OFFSET(0)] doi_prefixes
    FROM `{cfg['datacite_records']}`
         LEFT JOIN UNNEST(attributes.alternateIdentifiers) alt_ids
    GROUP BY 1
    HAVING COUNTIF(alt_ids.alternateIdentifierType IN ('IGSN','arXiv')) = 0
""").to_dataframe().doi_prefixes
print(f'{len(prefixes):,} DOI prefixes', flush=True)


def prefix_search_terms(batch):
    terms = []
    for d in batch:
        if d == '10.48550':  # arXiv
            continue
        terms.append(d)
        terms.append('\\"' + d.replace('10.', '10. ', 1) + '\\"')  # line-broken variant
    return ' OR '.join(terms)


def fetch(query, tag):
    for attempt in range(3):
        try:
            res = dsl.query_iterative(query, verbose=False)
            pubs = res['publications'] if 'publications' in res.json else []
            return pd.DataFrame(pubs) if pubs else pd.DataFrame(columns=['id'])
        except Exception as e:
            print(f'  {tag}: attempt {attempt+1} failed: {str(e)[:150]}', flush=True)
            time.sleep(20 * (attempt + 1))
    sys.exit(f'{tag}: giving up after 3 attempts')  # fail loudly, never drop a batch silently


for i in range(N_BATCHES):
    out = os.path.join(CKPT, f'batch_{i:03d}.parquet')
    if os.path.exists(out):
        continue
    subquery = '"' + prefix_search_terms(prefixes[i::N_BATCHES]) + '"'
    count = dsl.query(f"""search publications for {subquery}
                          where year in [{YEARS[0]}:{YEARS[1]}]
                          return publications[id] limit 1""").count_total
    print(f'batch {i}: {count:,} results', flush=True)
    if count < 50000:
        df = fetch(f"""search publications for {subquery}
                       where year in [{YEARS[0]}:{YEARS[1]}]
                       return publications[id]""", f'batch {i}')
    else:
        # query_iterative truncates at 50k; split oversized batches by year
        parts = []
        for y in range(YEARS[0], YEARS[1] + 1):
            parts.append(fetch(f"""search publications for {subquery} where year = {y}
                                   return publications[id]""", f'batch {i}/{y}'))
        df = pd.concat(parts) if parts else pd.DataFrame(columns=['id'])
    df = df[['id']].drop_duplicates() if len(df) else pd.DataFrame(columns=['id'])
    df.to_parquet(out)
    print(f'batch {i}: saved {len(df):,} ids', flush=True)

ids = pd.concat([pd.read_parquet(os.path.join(CKPT, f)) for f in sorted(os.listdir(CKPT))
                 if f.endswith('.parquet')]).drop_duplicates()
print(f'{len(ids):,} distinct publication ids', flush=True)
client.load_table_from_dataframe(
    ids, f"{cfg['work_dataset']}.doi_candidates",
    job_config=bigquery.LoadJobConfig(write_disposition='WRITE_TRUNCATE')).result()
print('loaded doi_candidates', flush=True)
