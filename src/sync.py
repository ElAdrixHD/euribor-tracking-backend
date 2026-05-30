#!/usr/bin/env python3
"""Daily Euribor 12m sync — fetch from BDE and upsert into Supabase.

Usage:
  python src/sync.py              # sync last 3 months (daily cron)
  python src/sync.py --backfill   # load full history from 1998 to today
"""

import argparse
import time
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

from bde_client import fetch_euribor_12m
from repository import get_client, latest_date, refresh_stats, upsert_rates

EURIBOR_START_YEAR = 1998  # first Euribor published 1998-12-30


def sync_daily(dry_run: bool = False) -> None:
    client = get_client()
    records = fetch_euribor_12m("3M")

    if dry_run:
        print(f"[dry-run] Would upsert {len(records)} records")
        return

    n = upsert_rates(client, records)
    refresh_stats(client)
    print(f"Upserted {n} records. Latest: {latest_date(client)}")


def backfill(dry_run: bool = False) -> None:
    client = get_client()
    current_year = date.today().year
    total = 0

    for year in range(EURIBOR_START_YEAR, current_year + 1):
        print(f"  Fetching {year}...")
        records = fetch_euribor_12m(str(year))

        if dry_run:
            print(f"  [dry-run] {year}: {len(records)} records")
        else:
            n = upsert_rates(client, records)
            total += n
            print(f"  {year}: {n} records")

        time.sleep(0.5)

    if not dry_run:
        refresh_stats(client)
        print(f"\nBackfill complete — {total} total records. Latest: {latest_date(client)}")


def main() -> None:
    load_dotenv(Path(__file__).parent.parent / ".env")

    parser = argparse.ArgumentParser(description="Euribor 12m BDE → Supabase sync")
    parser.add_argument("--backfill", action="store_true", help="Load full history from 1998")
    parser.add_argument("--dry-run", action="store_true", help="Fetch but do not write to DB")
    args = parser.parse_args()

    if args.backfill:
        print(f"Starting full historical backfill ({EURIBOR_START_YEAR} → today)...")
        backfill(dry_run=args.dry_run)
    else:
        print("Running daily sync (last 3 months)...")
        sync_daily(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
