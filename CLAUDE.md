# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies (editable install)
pip install -e .

# Daily sync (last 3 months)
python src/sync.py

# Full historical backfill (1998 → today, ~28 years, year-by-year)
python src/sync.py --backfill

# Dry run (fetch only, no DB writes)
python src/sync.py --dry-run
python src/sync.py --backfill --dry-run
```

Requires `.env` at project root with `SUPABASE_URL` and `SUPABASE_KEY` (see `.env.example`).

## Architecture

This is a Python data pipeline that fetches Euribor 12-month daily rates from Spain's BDE (Banco de España) public API and stores them in Supabase. It runs as a GitHub Actions cron job at 9:00 UTC daily.

**Data flow:**
```
BDE REST API → bde_client.py → repository.py → Supabase (euribor_rates table)
                                              → refresh_stats cache
```

**Three source files:**
- `src/bde_client.py` — HTTP client for BDE's `listaSeries` endpoint. BDE requires browser-like headers or returns schema metadata instead of rate data. Uses exponential backoff on failure. Series code `D_DNBAF172` = 12m Euribor daily.
- `src/repository.py` — Supabase client wrapper: upsert in 500-row chunks, call `refresh_euribor_stats()` after writes.
- `src/sync.py` — Entrypoint. `sync_daily` fetches last 3 months (`rango="3M"`); `backfill` loops year by year with 0.5s sleep between years.

**Supabase schema (migrations in order):**
1. `euribor_rates` table — `rate_date DATE PK, rate NUMERIC(7,3)`. Public read via RLS, writes restricted to `service_role`.
2. `euribor_monthly_avg(row_limit)` — RPC returning monthly averages.
3. `get_euribor_stats()` / `_compute_euribor_stats()` — Single-call JSON payload with spot rates, averages (weekly/MTD/quarterly/YTD), deltas, extremes, trend stats, streak, and chart series (daily last 90 days with MA7/MA30, monthly last 12, yearly last 5).
4. `euribor_stats_cache` table — Single-row cache (id=1 enforced by CHECK constraint). `get_euribor_stats()` is `SECURITY DEFINER` and reads from this cache; `_compute_euribor_stats()` does the heavy SQL and is service_role-only; `refresh_euribor_stats()` writes to the cache and is called by `repository.refresh_stats()` after every sync.

**Security model:** `anon`/`authenticated` can only read `euribor_rates` (via RLS) and call `get_euribor_stats()` (reads pre-computed cache). All writes and recomputation require `service_role`.
