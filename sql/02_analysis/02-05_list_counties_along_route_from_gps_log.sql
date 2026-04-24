-- ============================================
-- [METADATA]
-- file       : 02-05_list_counties_along_route_from_gps_log.sql
-- category   : analysis
-- tags       : #route #county #gps #spatial-join #postgres_fdw #foreign-table
-- difficulty : ★★☆ (intermediate)
-- estimated_complexity : medium — spatial join with route geometry; 1–5s depending on route length
-- execution_time : 1–5s
-- ============================================
-- purpose : List US counties along a route stored in the gps_log table,
--           in travel order, with route length per county and ACS demographics.
-- input   : record_id from gps_log, ACS survey_year
-- output  : counties the route passes through, sorted by distance from route start
-- tables  : admin_us.counties, census_us.acs_demographics (foreign tables via postgres_fdw),
--           gps_log (local table in the same DB as this query is run)
-- created : 2026-04-23
-- updated : 2026-04-24
--
-- Example route (record_id = 384):
--   Empire State Building, New York City → US Capitol, Washington DC
--   Passes through: NY → NJ → DE → MD → DC
-- prerequisite: postgres_fdw configured (see [PREREQUISITES] section below)
-- ============================================

-- ============================================
-- [PREREQUISITES]
-- ============================================
-- Run this query on the DB that contains gps_log (e.g. "travel").
-- admin_us and census_us live in a separate DB (e.g. "gis").
-- The steps below make those schemas available as foreign tables.
--
-- Assumed DB layout:
--   DB "gis"    — admin_us.counties, census_us.acs_demographics
--   DB "travel" — public.gps_log  ← run this query here
--
-- ── Step 1 : Enable postgres_fdw (run once per DB) ──────────────────────────
--
--   CREATE EXTENSION IF NOT EXISTS postgres_fdw;
--
-- ── Step 2 : Create a foreign server pointing to the gis DB ─────────────────
--
--   CREATE SERVER gis
--     FOREIGN DATA WRAPPER postgres_fdw
--     OPTIONS (host 'localhost', port '5432', dbname 'gis');
--
--   -- Adjust host/port/dbname to match your environment.
--   -- If gis and travel are on the same PostgreSQL instance, 'localhost' is correct.
--
-- ── Step 3 : Map the local user to the remote user ──────────────────────────
--
--   CREATE USER MAPPING FOR CURRENT_USER
--     SERVER gis
--     OPTIONS (user '<db_user>', password '<db_password>');
--
--   -- Replace <db_user> and <db_password> with the credentials used to connect to the gis DB.
--
-- ── Step 4 : Import the foreign schemas (run once) ──────────────────────────
--
--   -- Create local schemas to hold the foreign table definitions
--   CREATE SCHEMA IF NOT EXISTS admin_us;
--   CREATE SCHEMA IF NOT EXISTS census_us;
--
--   -- Import admin_us.counties (geometry + attributes)
--   IMPORT FOREIGN SCHEMA admin_us
--     LIMIT TO (counties)
--     FROM SERVER gis
--     INTO admin_us;
--
--   -- Import census_us.acs_demographics (ACS population data)
--   IMPORT FOREIGN SCHEMA census_us
--     LIMIT TO (acs_demographics)
--     FROM SERVER gis
--     INTO census_us;
--
-- ── Step 5 : Verify the foreign tables ──────────────────────────────────────
--
--   SELECT geoid, name, stusps FROM admin_us.counties LIMIT 3;
--   SELECT geoid, total_pop FROM census_us.acs_demographics LIMIT 3;
--
-- ── Optional : Skip postgres_fdw if running on the gis DB directly ──────────
--
--   If gps_log is imported into the gis DB (e.g. via IMPORT FOREIGN SCHEMA in
--   the opposite direction, or by copying the table), Steps 1–4 are not needed.
--   Simply ensure gps_log is accessible and run the query as-is.
--
-- Once all prerequisites are met, edit the parameters below and run.
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        384  AS target_record_id,  -- record_id to analyse from the gps_log table
        2022 AS survey_year        -- ACS vintage year for demographic columns
)
-- ============================================

-- [MAIN QUERY] No changes needed below this line
SELECT
    c.geoid,
    c.name          AS county_name,
    c.namelsad,
    c.stusps,
    c.state_name,
    a.total_pop,

    -- Route length within this county (km and miles)
    ROUND(
        (ST_Length(
            ST_Intersection(c.geom, g.geom)::geography
        ) / 1000)::numeric,
        2
    )               AS route_length_in_county_km,
    ROUND(
        (ST_Length(
            ST_Intersection(c.geom, g.geom)::geography
        ) / 1609.344)::numeric,
        2
    )               AS route_length_in_county_mi,

    -- Distance from route start to this county's entry point (km and miles)
    -- Used for ORDER BY to reproduce travel order.
    -- ST_ClosestPoint finds the point on the county geometry nearest to the
    -- route start; ST_LineLocatePoint converts that to a 0–1 fraction along
    -- the route; ST_LineSubstring extracts the sub-line up to that fraction.
    ROUND(
        (ST_Length(
            ST_LineSubstring(
                g.geom,
                0,
                ST_LineLocatePoint(
                    g.geom,
                    ST_ClosestPoint(c.geom, ST_StartPoint(g.geom))
                )
            )::geography
        ) / 1000)::numeric,
        2
    )               AS distance_from_start_km,
    ROUND(
        (ST_Length(
            ST_LineSubstring(
                g.geom,
                0,
                ST_LineLocatePoint(
                    g.geom,
                    ST_ClosestPoint(c.geom, ST_StartPoint(g.geom))
                )
            )::geography
        ) / 1609.344)::numeric,
        2
    )               AS distance_from_start_mi,

    -- GPS log metadata
    g.record_id

FROM  admin_us.counties              c   -- foreign table via postgres_fdw (gis DB)
CROSS JOIN gps_log                   g   -- local table in this DB
CROSS JOIN params
LEFT  JOIN census_us.acs_demographics a   -- foreign table via postgres_fdw (gis DB)
      ON  c.geoid      = a.geoid
      AND a.survey_year = params.survey_year

WHERE g.record_id = params.target_record_id
  AND ST_Intersects(c.geom, g.geom)

ORDER BY distance_from_start_km;


-- ============================================
-- [NOTES]
-- · Typical execution time : 1–5 s (depends on route complexity and county count)
-- · Typical row count      : 10–40 counties for a regional route
--
-- Output columns:
--   geoid                    5-digit county FIPS (primary key, joins to census tables)
--   county_name              County name without type (e.g. "Hudson")
--   namelsad                 Full name with type (e.g. "Hudson County")
--   stusps                   2-letter state code (e.g. "NJ")
--   state_name               Full state name
--   total_pop                ACS total population (NULL if no ACS record for survey_year)
--   route_length_in_county_km  Route length within this county (km)
--   route_length_in_county_mi  Route length within this county (miles)
--   distance_from_start_km   Distance from route start to county entry (km) — sort key
--   distance_from_start_mi   Distance from route start to county entry (miles)
--   record_id                GPS log record ID (for reference)
--
-- gps_log table location:
--   This query is designed to run on the DB that contains gps_log (e.g. "travel").
--   admin_us.counties and census_us.acs_demographics are accessed as foreign tables
--   via postgres_fdw (see [PREREQUISITES] above).
--   Typical schema: public.gps_log or work.gps_log
--   Required columns: record_id (integer), geom (geometry LineString/MultiLineString, SRID 4326)
--
-- Troubleshooting:
--
--   ERROR: relation "admin_us.counties" does not exist
--   → postgres_fdw is not configured, or IMPORT FOREIGN SCHEMA has not been run
--   → Complete Steps 1–4 in [PREREQUISITES] above
--
--   ERROR: relation "gps_log" does not exist
--   → Table is in a different schema; prefix with the schema name (e.g. public.gps_log)
--     or set search_path: SET search_path TO public;
--
--   No rows returned
--   → Check that the specified record_id exists in the gps_log table:
--     SELECT record_id, ST_GeometryType(geom) FROM gps_log WHERE record_id = 384;
--
-- ACS total_pop NULL:
--   Returns NULL for counties with no ACS record for the specified survey_year,
--   or for counties where ACS returned sentinel values (very small populations).
--   The route result is still returned; only the total_pop column is NULL.
--
-- Geometry type handling:
--   gps_log.geom is assumed to be a LineString or MultiLineString in WGS84 (SRID 4326).
--   If the geometry is stored as geography, remove the ::geography cast in ST_Length
--   and use ST_Length(ST_Intersection(...), true) instead.
--
-- Customisation:
--   Filter by state:
--     AND c.stusps IN ('NY', 'NJ', 'PA')
--
--   Add population density:
--     ROUND(a.total_pop::numeric / NULLIF(c.aland / 1e6, 0)::numeric, 1) AS pop_per_km2
--
--   Process multiple records:
--     WHERE g.record_id IN (384, 385, 386) AND ST_Intersects(...)
--     (ORDER BY record_id, distance_from_start_km for multi-route output)
--
-- Comparison with Japan version (02-05c_list_cities_along_route_from_gps_log.sql):
--   JP: municipality level (v_census_municipality), postgres_fdw to import census tables
--       into the GPS log DB
--   US: county level (admin_us.counties), postgres_fdw to import GIS tables
--       into the GPS log DB — same direction, equivalent setup
--   Spatial logic (ST_Intersection / ST_LineSubstring / ST_LineLocatePoint) is identical.
-- ============================================
