-- Expose refreshed_at from the cache so clients can display when data was last updated.
CREATE OR REPLACE FUNCTION get_euribor_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT jsonb_build_object(
        'data',         data,
        'refreshed_at', refreshed_at
    )
    FROM euribor_stats_cache
    WHERE id = 1;
$$;

GRANT EXECUTE ON FUNCTION get_euribor_stats() TO anon, authenticated, service_role;
