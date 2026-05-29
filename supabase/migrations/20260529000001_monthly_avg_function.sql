CREATE OR REPLACE FUNCTION euribor_monthly_avg(row_limit integer DEFAULT 12)
RETURNS TABLE (month date, avg_rate numeric)
LANGUAGE sql
SECURITY INVOKER
AS $$
    SELECT
        DATE_TRUNC('month', rate_date)::date AS month,
        ROUND(AVG(rate)::numeric, 3)         AS avg_rate
    FROM euribor_rates
    GROUP BY 1
    ORDER BY 1 DESC
    LIMIT row_limit;
$$;

GRANT EXECUTE ON FUNCTION euribor_monthly_avg TO anon, authenticated, service_role;
