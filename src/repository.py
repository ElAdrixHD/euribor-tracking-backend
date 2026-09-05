import os
import time
from typing import Callable, TypeVar

import httpx
from supabase import Client, ClientOptions, create_client

T = TypeVar("T")


def _execute_with_retry(fn: Callable[[], T], max_retries: int = 3, delay: float = 2.0) -> T:
    """Execute a Supabase operation with retry on transient network/transport errors."""
    for attempt in range(max_retries):
        try:
            return fn()
        except httpx.HTTPError as exc:
            if attempt == max_retries - 1:
                raise
            sleep_time = delay * (2**attempt)
            print(
                f"Supabase request failed ({exc}). Retrying in {sleep_time:.1f}s (attempt {attempt + 1}/{max_retries})..."
            )
            time.sleep(sleep_time)


def get_client() -> Client:
    url = os.environ["SUPABASE_URL"]
    key = os.environ["SUPABASE_KEY"]
    # Force HTTP/1.1: httpx HTTP/2 has known stream disconnect issues with Cloudflare/Supabase in CI environments
    http_client = httpx.Client(http2=False, timeout=30.0)
    options = ClientOptions(httpx_client=http_client)
    return create_client(url, key, options=options)


def upsert_rates(client: Client, records: list[dict]) -> int:
    """Insert records, ignoring duplicates. Returns number of rows sent."""
    if not records:
        return 0

    chunk_size = 500
    for i in range(0, len(records), chunk_size):
        chunk = records[i : i + chunk_size]
        _execute_with_retry(
            lambda: client.table("euribor_rates").upsert(chunk, ignore_duplicates=True).execute()
        )

    return len(records)


def monthly_averages(client: Client, limit: int = 12) -> list[dict]:
    """Return monthly averages of the 12m Euribor, most recent first."""
    result = _execute_with_retry(
        lambda: client.rpc("euribor_monthly_avg", {"row_limit": limit}).execute()
    )
    return result.data


def refresh_stats(client: Client) -> None:
    """Recompute and cache Euribor stats after a data upsert."""
    _execute_with_retry(lambda: client.rpc("refresh_euribor_stats").execute())


def latest_date(client: Client) -> str | None:
    result = _execute_with_retry(
        lambda: client.table("euribor_rates")
        .select("rate_date")
        .order("rate_date", desc=True)
        .limit(1)
        .execute()
    )
    return result.data[0]["rate_date"] if result.data else None
