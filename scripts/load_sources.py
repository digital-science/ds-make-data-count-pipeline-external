#!/usr/bin/env python3
"""Load external sources and lexicons into ${work_dataset}.

1. EuropePMC Text-Mined Terms accession annotations (downloads the per-family CSVs from
   https://europepmc.org/pub/databases/pmc/TextMinedTerms/) -> eupmc_text_mined_terms
2. lexicons/accession_patterns.json (+ priors for pattern-less families) -> accession_families
3. lexicons/cue_lexicon.json -> classification_cues

See docs/sources.md for family selection rationale and known false-positive families.
"""
import json, os, subprocess, sys
import yaml
from google.cloud import bigquery

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = yaml.safe_load(open(os.path.join(HERE, 'tables.yaml')))
DS = cfg['work_dataset']
client = bigquery.Client(project=cfg.get('project', DS.split('.')[0]))

TMT_BASE = 'https://europepmc.org/pub/databases/pmc/TextMinedTerms'
FAMILIES = ('geo gen bioproject biosample refseq pdb uniprot ensembl arrayexpress pxd '
            'metabolights chembl interpro pfam dbgap emdb empiar cellosaurus gisaid '
            'biomodels biostudies intact reactome rfam rnacentral uniparc metagenomics hpa').split()

# family (TMT file name) -> key in accession_patterns.json; None = no pattern (prior only)
PATTERN_KEYS = {
    'geo': 'GEO', 'gen': 'GenBank_ENA_DDBJ', 'bioproject': 'BioProject',
    'biosample': 'BioSample', 'refseq': 'RefSeq', 'pdb': 'PDB', 'uniprot': 'UniProt',
    'ensembl': 'Ensembl', 'arrayexpress': 'ArrayExpress', 'pxd': 'PRIDE',
    'metabolights': 'MetaboLights', 'chembl': 'ChEMBL', 'interpro': 'InterPro',
    'pfam': 'Pfam', 'dbgap': 'dbGaP', 'emdb': 'EMDB', 'empiar': 'EMPIAR',
    'cellosaurus': 'Cellosaurus', 'gisaid': 'GISAID'}
EXTRA_PRIORS = {
    'biomodels': 'primary-leaning', 'biostudies': 'primary-leaning',
    'metagenomics': 'primary-leaning', 'reactome': 'secondary-leaning',
    'rfam': 'secondary-leaning', 'rnacentral': 'secondary-leaning',
    'uniparc': 'secondary-leaning', 'hpa': 'secondary-leaning', 'intact': 'secondary-leaning'}


def download_tmt(dest):
    os.makedirs(dest, exist_ok=True)
    for fam in FAMILIES:
        out = os.path.join(dest, f'{fam}.csv')
        if os.path.exists(out):
            continue
        print(f'downloading {fam}.csv', flush=True)
        subprocess.run(['curl', '-sSf', '--retry', '3', '-o', out, f'{TMT_BASE}/{fam}.csv'],
                       check=True)


def load_tmt(dest):
    combined = os.path.join(dest, 'tmt_all.csv')
    with open(combined, 'w') as w:
        for fam in FAMILIES:
            with open(os.path.join(dest, f'{fam}.csv')) as f:
                next(f)  # header
                for line in f:
                    if line.strip():
                        w.write(line.rstrip('\n') + f',{fam}\n')
    schema = [bigquery.SchemaField(n, 'STRING') for n in
              ('accession', 'pmcid', 'ext_id', 'source', 'family')]
    with open(combined, 'rb') as f:
        client.load_table_from_file(
            f, f'{DS}.eupmc_text_mined_terms',
            job_config=bigquery.LoadJobConfig(
                source_format='CSV', schema=schema, write_disposition='WRITE_TRUNCATE',
                clustering_fields=['family', 'accession'])).result()
    print('loaded eupmc_text_mined_terms', flush=True)


def load_lexicons():
    pat = json.load(open(os.path.join(HERE, 'lexicons', 'accession_patterns.json')))
    rows = [dict(family=f, patterns_key=k, pattern=pat[k]['pattern'],
                 fp_risk=pat[k]['fp_risk'], default_type_prior=pat[k]['default_type_prior'])
            for f, k in PATTERN_KEYS.items()]
    rows += [dict(family=f, patterns_key=None, pattern=None, fp_risk='low',
                  default_type_prior=p) for f, p in EXTRA_PRIORS.items()]
    client.load_table_from_json(rows, f'{DS}.accession_families',
        job_config=bigquery.LoadJobConfig(write_disposition='WRITE_TRUNCATE',
            schema=[bigquery.SchemaField(n, 'STRING') for n in
                    ('family', 'patterns_key', 'pattern', 'fp_risk', 'default_type_prior')])
        ).result()
    print(f'loaded accession_families ({len(rows)})', flush=True)

    lex = json.load(open(os.path.join(HERE, 'lexicons', 'cue_lexicon.json')))
    cues = ([dict(cue_id=c['id'], direction='primary', pattern=c['pattern'], weight=c['weight'])
             for c in lex['primary_cues']] +
            [dict(cue_id=c['id'], direction='secondary', pattern=c['pattern'], weight=c['weight'])
             for c in lex['secondary_cues']])
    client.load_table_from_json(cues, f'{DS}.classification_cues',
        job_config=bigquery.LoadJobConfig(write_disposition='WRITE_TRUNCATE',
            schema=[bigquery.SchemaField('cue_id', 'STRING'),
                    bigquery.SchemaField('direction', 'STRING'),
                    bigquery.SchemaField('pattern', 'STRING'),
                    bigquery.SchemaField('weight', 'FLOAT')])).result()
    print(f'loaded classification_cues ({len(cues)})', flush=True)


if __name__ == '__main__':
    dest = os.path.join(HERE, 'sources_tmp')
    download_tmt(dest)
    load_tmt(dest)
    load_lexicons()
