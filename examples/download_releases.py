#!/usr/bin/env python3
"""Download every Make Data Count data-citations release that you don't already have, as CSV.

What it does
    1. Signs you in to Google (a browser window opens the first time).
    2. Reads the public `release_changelog` table to see which releases exist.
    3. For each release without a file in the output folder, downloads that release's snapshot
       table to `data_citations_<release>.csv` and checks the row count against the changelog.

Releases you already have are skipped, so it is safe to re-run (monthly, or whenever).
A download that is interrupted (network drop, laptop sleep, Ctrl-C) RESUMES from where it stopped
the next time you run the script, and short network failures are retried automatically.

Setup (once)
    pip install google-cloud-bigquery pydata-google-auth

Run
    python download_releases.py                  # downloads missing releases into ./releases
    python download_releases.py --list           # just show what exists / what you have / what is missing
    python download_releases.py --out-dir /data/mdc
    python download_releases.py --fresh          # discard any partly-downloaded file and start over

Notes
    - You need a Google account, nothing else: the data is public (CC0) and readable by any signed-in
      Google user. You do NOT need your own Google Cloud project, and the download is free: it
      reads table rows directly and runs no queries.
    - A release is ~8.7 million rows (~650 MB of CSV). Expect roughly 12 minutes per release.
    - While downloading, a release lives in `*.csv.part` with a small `*.csv.progress` note beside it.
      Only a complete file whose row count matches the changelog is renamed to `*.csv`.
    - Data: https://console.cloud.google.com/bigquery?project=ds-make-data-count&d=public&page=dataset
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from pathlib import Path

try:
    import google.auth
    import requests
    from google.api_core import exceptions as gexc
    from google.auth.exceptions import DefaultCredentialsError, RefreshError
    from google.cloud import bigquery
except ImportError:
    sys.exit("Missing packages. Run:  pip install google-cloud-bigquery pydata-google-auth")

DATA_PROJECT = "ds-make-data-count"
DATA_DATASET = "public"
CHANGELOG_TABLE = "release_changelog"
SCOPES = ["https://www.googleapis.com/auth/bigquery"]
PAGE_SIZE = 50_000          # rows per request
REQUEST_TIMEOUT = 120       # seconds per request before it is retried
PROGRESS_EVERY = 500_000    # rows between progress lines
MAX_ATTEMPTS = 6            # automatic retries (each resumes from the last checkpoint) before giving up


def get_credentials(force_login: bool = False):
    """Use existing Google credentials if present, otherwise open a browser to sign in."""
    if not force_login:
        try:
            creds, _ = google.auth.default(scopes=SCOPES)
            return creds
        except DefaultCredentialsError:
            pass
    try:
        import pydata_google_auth
        import pydata_google_auth.cache
    except ImportError:
        sys.exit("Missing package. Run:  pip install pydata-google-auth")
    print("Signing in to Google: a browser window will open. Choose your Google account and click Allow.")
    print("(If no browser opens, copy the link printed below into one.)")
    # Credentials are cached on disk, so only the first run (or a --login run) opens the browser.
    cache = pydata_google_auth.cache.REAUTH if force_login else pydata_google_auth.cache.READ_WRITE
    return pydata_google_auth.get_user_credentials(SCOPES, credentials_cache=cache)


# Failures worth retrying: network drops and Google-side slowness. Permission/not-found errors are not.
RETRYABLE = (gexc.RetryError, gexc.ServiceUnavailable, gexc.GatewayTimeout, gexc.DeadlineExceeded,
             gexc.InternalServerError, gexc.TooManyRequests, requests.exceptions.RequestException,
             ConnectionError, TimeoutError)


def explain(err: Exception) -> str:
    """Turn the common failures into a sentence a non-specialist can act on."""
    if isinstance(err, (gexc.Unauthorized, RefreshError)):
        return "Your Google sign-in is missing or has expired. Re-run with --login to sign in again."
    if isinstance(err, gexc.Forbidden):
        return ("Google says you don't have access to this data. Make sure you signed in with a Google "
                "account (not a restricted work account that blocks sharing), then re-run with --login.")
    if isinstance(err, gexc.NotFound):
        return "The table was not found (it may have been retired). Skipping."
    if isinstance(err, (gexc.ServiceUnavailable, gexc.GatewayTimeout, gexc.DeadlineExceeded, TimeoutError)):
        return "Google was slow or unavailable. Wait a minute and re-run: finished releases are kept."
    return f"{type(err).__name__}: {err}"


def list_releases(client: bigquery.Client) -> list[dict]:
    """Read the public release_changelog (no query job, so no billing project needed)."""
    table = client.get_table(f"{DATA_PROJECT}.{DATA_DATASET}.{CHANGELOG_TABLE}")
    rows = [dict(r.items()) for r in client.list_rows(table, timeout=REQUEST_TIMEOUT)]
    rows = [r for r in rows if r.get("release") and r.get("snapshot_table")]
    return sorted(rows, key=lambda r: r["release"])


def csv_path(out_dir: Path, release: str) -> Path:
    return out_dir / f"data_citations_{release}.csv"


def already_have(out_dir: Path, release: str) -> bool:
    """A release counts as downloaded only if its file exists and is not empty."""
    p = csv_path(out_dir, release)
    return p.exists() and p.stat().st_size > 0


def _sync(fh) -> int:
    """Force everything written so far onto disk and return the file size in bytes."""
    fh.flush()
    os.fsync(fh.fileno())
    return os.fstat(fh.fileno()).st_size


def _write_checkpoint(path: Path, table, rows: int, nbytes: int) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({"rows": rows, "bytes": nbytes, "num_rows": table.num_rows,
                               "table_modified": str(table.modified)}))
    tmp.replace(path)           # atomic: the note is never half-written


def _resume_point(part: Path, ckpt: Path, table, fresh: bool) -> tuple[int, int]:
    """(rows, bytes) of the last intact point in an interrupted download, or (0, 0) to start over.

    Resuming is only safe if the table has not changed since the checkpoint was written, and the
    partial file is at least as long as the checkpoint says. Anything else starts again.
    """
    usable = None
    if not fresh and part.exists() and ckpt.exists():
        try:
            cp = json.loads(ckpt.read_text())
            if (cp["num_rows"] == table.num_rows and cp["table_modified"] == str(table.modified)
                    and 0 < cp["bytes"] <= part.stat().st_size and 0 <= cp["rows"] <= table.num_rows):
                usable = (cp["rows"], cp["bytes"])
        except (OSError, ValueError, KeyError):
            usable = None
    if usable is None:
        part.unlink(missing_ok=True)
        ckpt.unlink(missing_ok=True)
        return 0, 0
    return usable


def _fetch(client, table, columns, part: Path, ckpt: Path, rows_done: int, bytes_done: int, t0: float) -> int:
    """Append rows from `rows_done` onwards to the partial file, checkpointing every page."""
    if bytes_done:
        os.truncate(part, bytes_done)   # drop anything written after the last checkpoint
    with part.open("a" if bytes_done else "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        if not bytes_done:
            writer.writerow(columns)
            _write_checkpoint(ckpt, table, 0, _sync(fh))
        n = rows_done
        for row in client.list_rows(table, start_index=rows_done, page_size=PAGE_SIZE, timeout=REQUEST_TIMEOUT):
            writer.writerow(["" if v is None else v for v in row.values()])
            n += 1
            if n % PAGE_SIZE == 0:
                _write_checkpoint(ckpt, table, n, _sync(fh))
            if n % PROGRESS_EVERY == 0:
                print(f"    {n:,} rows ({time.time() - t0:,.0f}s)")
        _sync(fh)
    return n


def download_release(client: bigquery.Client, rel: dict, out_dir: Path, fresh: bool = False) -> None:
    release, snapshot, expected = rel["release"], rel["snapshot_table"], rel.get("row_count")
    final = csv_path(out_dir, release)
    part = final.with_name(final.name + ".part")
    ckpt = final.with_name(final.name + ".progress")
    # snapshot_table is recorded as "public.data_citations_YYYYMM"; use just the table name
    table_id = f"{DATA_PROJECT}.{DATA_DATASET}.{snapshot.split('.')[-1]}"

    t0, n = time.time(), 0
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            table = client.get_table(table_id)
            columns = [f.name for f in table.schema]
            rows_done, bytes_done = _resume_point(part, ckpt, table, fresh and attempt == 1)
            if attempt == 1:
                verb = f"resuming from row {rows_done:,} of" if rows_done else "downloading"
                print(f"  {verb} {release}: {table.num_rows:,} rows -> {final}")
            n = _fetch(client, table, columns, part, ckpt, rows_done, bytes_done, t0)
            break
        except RETRYABLE as err:
            if attempt == MAX_ATTEMPTS:
                raise
            wait = min(60, 5 * 2 ** (attempt - 1))
            print(f"  interrupted ({type(err).__name__}); retrying in {wait}s and resuming "
                  f"(attempt {attempt + 1} of {MAX_ATTEMPTS})")
            time.sleep(wait)

    if (expected is not None and n != expected) or n != table.num_rows:
        part.unlink(missing_ok=True)
        ckpt.unlink(missing_ok=True)
        raise RuntimeError(f"row count mismatch for {release}: downloaded {n:,}, expected "
                           f"{(expected if expected is not None else table.num_rows):,}. "
                           "The partial file was discarded; re-run to download it again.")
    part.replace(final)         # only a complete, verified file ever gets the final name
    ckpt.unlink(missing_ok=True)
    print(f"  done: {n:,} rows in {time.time() - t0:,.0f}s")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out-dir", default="releases", help="folder for the CSV files (default: ./releases)")
    ap.add_argument("--list", action="store_true", help="show releases and what you have, then stop")
    ap.add_argument("--login", action="store_true", help="ignore saved credentials and sign in again")
    ap.add_argument("--fresh", action="store_true", help="discard any partly-downloaded file and start over")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        creds = get_credentials(force_login=args.login)
        # project= is only the quota/billing label for the client; reading public rows runs no jobs
        client = bigquery.Client(project=DATA_PROJECT, credentials=creds)
        releases = list_releases(client)
    except Exception as err:    # noqa: BLE001 - we want one readable message, not a traceback
        print(f"Could not read the list of releases. {explain(err)}", file=sys.stderr)
        return 1

    if not releases:
        print("No releases found in the changelog.", file=sys.stderr)
        return 1

    have = [r for r in releases if already_have(out_dir, r["release"])]
    missing = [r for r in releases if r not in have]
    print(f"Releases available: {', '.join(r['release'] for r in releases)}")
    print(f"Already downloaded: {', '.join(r['release'] for r in have) or 'none'}")
    print(f"To download:        {', '.join(r['release'] for r in missing) or 'nothing, you are up to date'}")
    if args.list or not missing:
        return 0

    failed = 0
    for rel in missing:
        try:
            download_release(client, rel, out_dir, fresh=args.fresh)
        except Exception as err:    # noqa: BLE001
            failed += 1
            print(f"  FAILED {rel['release']}: {explain(err)}", file=sys.stderr)
    print("Finished." if not failed else f"Finished with {failed} failure(s); re-run to resume them.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
