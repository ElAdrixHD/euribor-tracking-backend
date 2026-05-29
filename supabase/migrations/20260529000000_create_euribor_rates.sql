CREATE TABLE euribor_rates (
    rate_date DATE PRIMARY KEY,
    rate      NUMERIC(7,3) NOT NULL
);

ALTER TABLE euribor_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public_read" ON euribor_rates
    FOR SELECT TO anon, authenticated
    USING (true);

GRANT SELECT ON euribor_rates TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON euribor_rates TO service_role;
