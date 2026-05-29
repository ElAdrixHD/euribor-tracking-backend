import time
from datetime import datetime

import httpx

BASE_URL = "https://app.bde.es/bierest/resources/srdatosapp"
SERIES_12M = "D_DNBAF172"

# BDE requires browser-like headers; plain curl triggers schema responses instead of data
HEADERS = {
    "Referer": "https://www.bde.es/",
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "es-ES,es;q=0.9,en;q=0.8",
}


def fetch_euribor_12m(rango: str, retries: int = 3) -> list[dict]:
    """Fetch 12-month Euribor daily rates for a given time range.

    rango: '3M' | '12M' | '36M' | '1999' | '2024' | ...
    Returns list of {"rate_date": "YYYY-MM-DD", "rate": float}
    """
    url = f"{BASE_URL}/listaSeries"
    params = {"idioma": "en", "series": SERIES_12M, "rango": rango}

    for attempt in range(retries):
        try:
            with httpx.Client(headers=HEADERS, timeout=30, follow_redirects=True) as client:
                resp = client.get(url, params=params)
                resp.raise_for_status()
                payload = resp.json()

            if not payload or "fechas" not in payload[0]:
                if attempt < retries - 1:
                    time.sleep(2 ** attempt)
                    continue
                return []

            fechas = payload[0]["fechas"]
            valores = payload[0]["valores"]

            return [
                {
                    "rate_date": datetime.fromisoformat(f.replace("Z", "+00:00")).date().isoformat(),
                    "rate": float(v),
                }
                for f, v in zip(fechas, valores)
                if v is not None
            ]

        except httpx.HTTPError as exc:
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)
            print(f"  Retry {attempt + 1}/{retries} for rango={rango}: {exc}")

    return []
