-- ============================================
-- [METADATA]
-- file       : 02-05_list_counties_along_route_from_gps_log.sql
-- category   : analysis
-- tags       : #route #county #gps #spatial-join
-- difficulty : ★★☆ (intermediate)
-- estimated_complexity : medium — spatial join with route geometry; 1–5s depending on route length
-- execution_time : 1–5s
-- ============================================
-- purpose : List US counties along a route stored in the gps_log table,
--           in travel order, with route length per county and ACS demographics.
-- input   : record_id from gps_log, ACS survey_year
-- output  : counties the route passes through, sorted by distance from route start
-- tables  : admin_us.counties, census_us.acs_demographics, gps_log (same DB)
-- created : 2026-04-23
-- updated : 2026-04-23
--
-- Example route (record_id = 384):
--   Empire State Building, New York City → US Capitol, Washington DC
--   Passes through: NY → NJ → PA → MD → DC
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

    -- Route length within this county (km)
    ROUND(
        (ST_Length(
            ST_Intersection(c.geom, g.geom)::geography
        ) / 1000)::numeric,
        2
    )               AS route_length_in_county_km,

    -- Distance from route start to this county's entry point (km)
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

    -- GPS log metadata
    g.record_id

FROM  admin_us.counties              c
CROSS JOIN gps_log                   g   -- same DB; no postgres_fdw required
CROSS JOIN params
LEFT  JOIN census_us.acs_demographics a
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
--   distance_from_start_km   Distance from route start to county entry (km) — sort key
--   record_id                GPS log record ID (for reference)
--
-- gps_log table location:
--   This query assumes gps_log is in the same PostgreSQL database (gis)
--   as admin_us and census_us. No postgres_fdw setup is required.
--   If gps_log is in a different database, configure postgres_fdw and
--   import the foreign table before running.
--   Typical schema: public.gps_log or work.gps_log
--   Required columns: record_id (integer), geom (geometry LineString/MultiLineString)
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
--   JP: municipality level (v_census_municipality), postgres_fdw to separate DB
--   US: county level (admin_us.counties), same DB — no postgres_fdw required
--   Spatial logic (ST_Intersection / ST_LineSubstring / ST_LineLocatePoint) is identical.
-- ============================================
