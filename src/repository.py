import os

from supabase import create_client, Client


def get_client() -> Client:
    url = os.environ["SUPABASE_URL"]
    key = os.environ["SUPABASE_KEY"]
    return create_client(url, key)


def upsert_rates(client: Client, records: list[dict]) -> int:
    """Insert records, ignoring duplicates. Returns number of rows sent."""
    if not records:
        return 0

    chunk_size = 500
    for i in range(0, len(records), chunk_size):
        chunk = records[i : i + chunk_size]
        client.table("euribor_rates").upsert(chunk, ignore_duplicates=True).execute()

    return len(records)


def monthly_averages(client: Client, limit: int = 12) -> list[dict]:
    """Return monthly averages of the 12m Euribor, most recent first."""
    result = client.rpc("euribor_monthly_avg", {"row_limit": limit}).execute()
    return result.data


def latest_date(client: Client) -> str | None:
    result = (
        client.table("euribor_rates")
        .select("rate_date")
        .order("rate_date", desc=True)
        .limit(1)
        .execute()
    )
    return result.data[0]["rate_date"] if result.data else None
