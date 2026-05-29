-- Single-call stats function: all app metrics in one JSON payload.
-- Usage: SELECT get_euribor_stats();
-- Via Supabase: supabase.rpc('get_euribor_stats')

CREATE OR REPLACE FUNCTION get_euribor_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
WITH

-- ── Ordered base ────────────────────────────────────────────────────────
ranked AS (
    SELECT rate_date, rate,
           ROW_NUMBER() OVER (ORDER BY rate_date DESC) AS rn
    FROM euribor_rates
),
today_row     AS (SELECT rate_date, rate FROM ranked WHERE rn = 1),
yesterday_row AS (SELECT rate_date, rate FROM ranked WHERE rn = 2),

-- ── Averages ────────────────────────────────────────────────────────────
avg_weekly AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date > (SELECT rate_date - 7 FROM today_row)
),
avg_mtd AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE)
),
last_closed_month AS (
    SELECT DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::date AS month_start,
           ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
      AND rate_date <  DATE_TRUNC('month', CURRENT_DATE)
),
prev_closed_month AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 months')
      AND rate_date <  DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
),
avg_quarterly AS (
    -- Last complete calendar quarter
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('quarter', CURRENT_DATE - INTERVAL '3 months')
      AND rate_date <  DATE_TRUNC('quarter', CURRENT_DATE)
),
avg_ytd AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('year', CURRENT_DATE)
),
avg_last_year AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('year', CURRENT_DATE - INTERVAL '1 year')
      AND rate_date <  DATE_TRUNC('year', CURRENT_DATE)
),
ma30 AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM (SELECT rate FROM euribor_rates ORDER BY rate_date DESC LIMIT 30) t
),
ma90 AS (
    SELECT ROUND(AVG(rate)::numeric, 3) AS val
    FROM (SELECT rate FROM euribor_rates ORDER BY rate_date DESC LIMIT 90) t
),

-- ── Extremes ────────────────────────────────────────────────────────────
ext_12m AS (
    SELECT MIN(rate) AS min_rate, MAX(rate) AS max_rate
    FROM euribor_rates
    WHERE rate_date > (SELECT rate_date - 365 FROM today_row)
),
ext_mtd AS (
    SELECT MIN(rate) AS min_rate, MAX(rate) AS max_rate
    FROM euribor_rates
    WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE)
),

-- ── Trend / dispersion (last 90 business days) ──────────────────────────
trend_stats AS (
    SELECT
        ROUND(STDDEV(rate)::numeric, 4) AS std_dev,
        ROUND(AVG(rate)::numeric, 3)    AS mean_rate,
        -- slope in rate-points per calendar day
        ROUND((REGR_SLOPE(rate, EXTRACT(EPOCH FROM rate_date)::float) * 86400)::numeric, 6) AS slope_per_day
    FROM (SELECT rate_date, rate FROM euribor_rates ORDER BY rate_date DESC LIMIT 90) t
),

-- ── Consecutive streak (last 63 business days) ──────────────────────────
delta_series AS (
    SELECT rate_date,
           rate - LAG(rate) OVER (ORDER BY rate_date) AS delta
    FROM (SELECT rate_date, rate FROM euribor_rates ORDER BY rate_date DESC LIMIT 63) t
),
streak_dir AS (
    SELECT SIGN(delta)::int AS dir
    FROM delta_series
    WHERE delta IS NOT NULL AND delta <> 0
    ORDER BY rate_date DESC LIMIT 1
),
streak_break AS (
    SELECT COALESCE(MAX(rate_date), '1900-01-01'::date) AS break_date
    FROM delta_series
    WHERE delta IS NOT NULL
      AND SIGN(delta) <> (SELECT dir FROM streak_dir)
),
streak AS (
    SELECT COUNT(*)::int AS days,
           (SELECT dir FROM streak_dir) AS dir
    FROM delta_series
    WHERE delta IS NOT NULL
      AND SIGN(delta) = (SELECT dir FROM streak_dir)
      AND rate_date > (SELECT break_date FROM streak_break)
),

-- ── Historical comparisons (12m) ────────────────────────────────────────
hist_12m AS (
    SELECT MIN(rate)  AS min_12m,
           MAX(rate)  AS max_12m,
           COUNT(*)   AS total_days,
           SUM(CASE WHEN rate <= (SELECT rate FROM today_row) THEN 1 ELSE 0 END) AS days_lte_today
    FROM euribor_rates
    WHERE rate_date > (SELECT rate_date - 365 FROM today_row)
)

SELECT jsonb_build_object(

    -- ── SPOT ─────────────────────────────────────────────────────────────
    'spot', jsonb_build_object(
        'today',     jsonb_build_object('date', t.rate_date, 'rate', t.rate),
        'yesterday', jsonb_build_object('date', y.rate_date, 'rate', y.rate),
        'd7', (
            SELECT jsonb_build_object('date', rate_date, 'rate', rate)
            FROM euribor_rates WHERE rate_date <= t.rate_date - 7
            ORDER BY rate_date DESC LIMIT 1
        ),
        'd30', (
            SELECT jsonb_build_object('date', rate_date, 'rate', rate)
            FROM euribor_rates WHERE rate_date <= t.rate_date - 30
            ORDER BY rate_date DESC LIMIT 1
        ),
        'd1y', (
            SELECT jsonb_build_object('date', rate_date, 'rate', rate)
            FROM euribor_rates WHERE rate_date <= t.rate_date - 365
            ORDER BY rate_date DESC LIMIT 1
        )
    ),

    -- ── AVERAGES ─────────────────────────────────────────────────────────
    'averages', jsonb_build_object(
        'weekly',            aw.val,
        'mtd',               am.val,
        'last_closed_month', jsonb_build_object('month', lcm.month_start, 'rate', lcm.val),
        'quarterly',         aq.val,
        'ytd',               ay.val,
        'last_closed_year',  aly.val,
        'ma30',              m30.val,
        'ma90',              m90.val
    ),

    -- ── DELTAS ───────────────────────────────────────────────────────────
    'deltas', jsonb_build_object(
        'daily', jsonb_build_object(
            'abs', ROUND((t.rate - y.rate)::numeric, 3),
            'pct', ROUND(((t.rate - y.rate) / NULLIF(y.rate, 0) * 100)::numeric, 3)
        ),
        'weekly', (
            SELECT jsonb_build_object(
                'abs', ROUND((t.rate - rate)::numeric, 3),
                'pct', ROUND(((t.rate - rate) / NULLIF(rate, 0) * 100)::numeric, 3)
            )
            FROM euribor_rates WHERE rate_date <= t.rate_date - 7
            ORDER BY rate_date DESC LIMIT 1
        ),
        'monthly', (
            SELECT jsonb_build_object(
                'abs', ROUND((t.rate - rate)::numeric, 3),
                'pct', ROUND(((t.rate - rate) / NULLIF(rate, 0) * 100)::numeric, 3)
            )
            FROM euribor_rates WHERE rate_date <= t.rate_date - 30
            ORDER BY rate_date DESC LIMIT 1
        ),
        'annual', (
            SELECT jsonb_build_object(
                'abs', ROUND((t.rate - rate)::numeric, 3),
                'pct', ROUND(((t.rate - rate) / NULLIF(rate, 0) * 100)::numeric, 3)
            )
            FROM euribor_rates WHERE rate_date <= t.rate_date - 365
            ORDER BY rate_date DESC LIMIT 1
        ),
        'vs_mtd',       ROUND((t.rate - am.val)::numeric, 3),
        'vs_ytd',       ROUND((t.rate - ay.val)::numeric, 3),
        'closed_month', ROUND((lcm.val - pcm.val)::numeric, 3)
    ),

    -- ── EXTREMES 12M ─────────────────────────────────────────────────────
    'extremes_12m', jsonb_build_object(
        'min',      e12.min_rate,
        'max',      e12.max_rate,
        'range',    ROUND((e12.max_rate - e12.min_rate)::numeric, 3),
        'date_min', (
            SELECT rate_date FROM euribor_rates
            WHERE rate_date > t.rate_date - 365 AND rate = e12.min_rate
            ORDER BY rate_date LIMIT 1
        ),
        'date_max', (
            SELECT rate_date FROM euribor_rates
            WHERE rate_date > t.rate_date - 365 AND rate = e12.max_rate
            ORDER BY rate_date DESC LIMIT 1
        )
    ),

    -- ── EXTREMES MTD ─────────────────────────────────────────────────────
    'extremes_mtd', jsonb_build_object(
        'min',      em.min_rate,
        'max',      em.max_rate,
        'range',    ROUND((em.max_rate - em.min_rate)::numeric, 3),
        'date_min', (
            SELECT rate_date FROM euribor_rates
            WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE) AND rate = em.min_rate
            ORDER BY rate_date LIMIT 1
        ),
        'date_max', (
            SELECT rate_date FROM euribor_rates
            WHERE rate_date >= DATE_TRUNC('month', CURRENT_DATE) AND rate = em.max_rate
            ORDER BY rate_date DESC LIMIT 1
        )
    ),

    -- ── TREND & DISPERSION ───────────────────────────────────────────────
    'trend', jsonb_build_object(
        'std_dev',       ts.std_dev,
        'volatility',    ROUND((ts.std_dev / NULLIF(ts.mean_rate, 0))::numeric, 4),
        'slope_per_day', ts.slope_per_day,
        -- threshold: 0.0002 pts/day ≈ 0.05 pts/quarter; tune as needed
        'direction',     CASE
                           WHEN ts.slope_per_day >  0.0002 THEN 'rising'
                           WHEN ts.slope_per_day < -0.0002 THEN 'falling'
                           ELSE 'sideways'
                         END
    ),

    -- ── STREAK ───────────────────────────────────────────────────────────
    'streak', jsonb_build_object(
        'days',      COALESCE((SELECT days FROM streak), 0),
        'direction', COALESCE(
            (SELECT CASE dir WHEN 1 THEN 'rising' WHEN -1 THEN 'falling' ELSE 'sideways' END FROM streak),
            'sideways'
        )
    ),

    -- ── HISTORICAL COMPARISONS ───────────────────────────────────────────
    'historical', jsonb_build_object(
        'min_12m',           h.min_12m,
        'max_12m',           h.max_12m,
        'vs_min_12m',        ROUND((t.rate - h.min_12m)::numeric, 3),
        'vs_max_12m',        ROUND((t.rate - h.max_12m)::numeric, 3),
        'percentile_12m',    CASE WHEN h.total_days > 0
                             THEN ROUND((h.days_lte_today::numeric / h.total_days * 100)::numeric, 1)
                             ELSE NULL END,
        'position_in_range', CASE WHEN (h.max_12m - h.min_12m) > 0
                             THEN ROUND(((t.rate - h.min_12m) / (h.max_12m - h.min_12m) * 100)::numeric, 1)
                             ELSE 0 END
    ),

    -- ── CHART DATA ───────────────────────────────────────────────────────
    'chart', jsonb_build_object(

        -- Last 12 closed monthly averages (bar chart)
        'monthly_series', (
            SELECT jsonb_agg(
                jsonb_build_object('month', month_start, 'rate', avg_rate, 'days', bdays)
                ORDER BY month_start
            )
            FROM (
                SELECT DATE_TRUNC('month', rate_date)::date AS month_start,
                       ROUND(AVG(rate)::numeric, 3)          AS avg_rate,
                       COUNT(*)                               AS bdays
                FROM euribor_rates
                WHERE rate_date < DATE_TRUNC('month', CURRENT_DATE)
                GROUP BY 1
                ORDER BY 1 DESC
                LIMIT 12
            ) ms
        ),

        -- Last 90 business days with MA7 / MA30 overlays (line chart)
        -- Fetches 120 rows so window functions are accurate for the oldest visible day.
        'daily_series', (
            SELECT jsonb_agg(
                jsonb_build_object('date', rate_date, 'rate', rate, 'ma7', ma7, 'ma30', ma30)
                ORDER BY rate_date
            )
            FROM (
                SELECT rate_date, rate, rn,
                    ROUND(AVG(rate) OVER (ORDER BY rate_date ROWS BETWEEN 6  PRECEDING AND CURRENT ROW)::numeric, 3) AS ma7,
                    ROUND(AVG(rate) OVER (ORDER BY rate_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW)::numeric, 3) AS ma30
                FROM (
                    SELECT rate_date, rate,
                           ROW_NUMBER() OVER (ORDER BY rate_date DESC) AS rn
                    FROM euribor_rates
                    ORDER BY rate_date DESC LIMIT 120
                ) base
            ) windowed
            WHERE rn <= 90
        )
    )

)
FROM today_row       t
CROSS JOIN yesterday_row  y
CROSS JOIN avg_weekly     aw
CROSS JOIN avg_mtd        am
CROSS JOIN last_closed_month  lcm
CROSS JOIN prev_closed_month  pcm
CROSS JOIN avg_quarterly  aq
CROSS JOIN avg_ytd        ay
CROSS JOIN avg_last_year  aly
CROSS JOIN ma30  m30
CROSS JOIN ma90  m90
CROSS JOIN ext_12m     e12
CROSS JOIN ext_mtd     em
CROSS JOIN trend_stats ts
CROSS JOIN hist_12m    h;
$$;

GRANT EXECUTE ON FUNCTION get_euribor_stats() TO anon, authenticated, service_role;
