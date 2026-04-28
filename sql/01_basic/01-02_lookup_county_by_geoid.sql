-- ============================================
-- [METADATA]
-- file       : 01-02_lookup_county_by_geoid.sql
-- category   : basic
-- tags       : #geoid #fips #county #lookup #demographics #population-density
-- difficulty : ★☆☆ (beginner)
-- estimated_complexity : low — key lookup with state-level aggregation, sub-second on indexed geoid
-- execution_time : <1s
-- ============================================
-- purpose : Retrieve county profile for a given 5-digit county GEOID (FIPS code):
--           name, state, land area, population, population density, and share
--           of the county's state population.
--           Query B (commented out below) lists all counties in a state.
-- input   : target_geoid (5-digit FIPS) — set in params block below
--           data_source, acs_year, dec_year — census vintage
-- output  : county_name, county_namelsad, geoid, state, state_name,
--           total_pop, area_km2, area_sq_mi,
--           pop_per_km2, pop_per_sq_mi, state_pop_share_pct, data_source
-- tables  : admin_us.counties  + census_us.acs_demographics   (data_source = 'acs')
--           admin_us.counties_2020 + census_us.decennial_census (data_source = 'decennial')
-- created : 2026-04-28
-- updated : 2026-04-28
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        '36061' AS target_geoid,   -- 5-digit county FIPS
        -- examples:
        --   '36061' = New York County (Manhattan), NY
        --   '06037' = Los Angeles County, CA   (most populous county)
        --   '17031' = Cook County (Chicago), IL
        --   '48301' = Loving County, TX         (least populous county, ~64 persons)
        'acs'   AS data_source,    -- 'acs'        → ACS 5-year estimates (census_us.acs_demographics)
                                   -- 'decennial'  → Decennial Census full count (census_us.decennial_census)
        2022    AS acs_year,       -- ACS vintage year        (used when data_source = 'acs')
        2020    AS dec_year        -- Decennial Census year   (used when data_source = 'decennial')
),
-- ============================================

-- Geometry abstraction: select county boundaries + aland from the vintage-appropriate table.
--   ACS 2022       → admin_us.counties      (TIGER/Line 2022: CT has 9 planning regions)
--   Decennial 2020 → admin_us.counties_2020 (TIGER/Line 2020: CT has 8 legacy counties)
geom_src AS (
    SELECT geoid, name, namelsad, stusps, state_name, aland
    FROM   admin_us.counties
    WHERE  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    SELECT geoid, name, namelsad, stusps, state_name, aland
    FROM   admin_us.counties_2020
    WHERE  (SELECT data_source FROM params) = 'decennial'
),

-- Demographic data abstraction: total_pop from ACS or Decennial.
-- Column names are identical across both tables (by design).
src AS (
    SELECT geoid, total_pop
    FROM   census_us.acs_demographics
    WHERE  survey_year = (SELECT acs_year FROM params)
      AND  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    SELECT geoid, total_pop
    FROM   census_us.decennial_census
    WHERE  census_year = (SELECT dec_year FROM params)
      AND  (SELECT data_source FROM params) = 'decennial'
),

-- State totals: sum all counties per state.
-- Used to compute each county's share of its state population.
state_pop AS (
    SELECT c.stusps, SUM(s.total_pop) AS state_total_pop
    FROM   geom_src c
    JOIN   src      s ON c.geoid = s.geoid
    GROUP BY c.stusps
)
-- ============================================

-- [QUERY A] Single county lookup   No changes needed below this line
SELECT
    c.geoid,
    c.name                                                                          AS county_name,
    c.namelsad                                                                      AS county_namelsad,
    c.stusps                                                                        AS state,
    c.state_name,
    (SELECT data_source FROM params)                                                AS data_source,
    s.total_pop,

    -- Land area (aland stored in m²; divide by 1e6 for km², by 2589988.11 for sq mi)
    ROUND((c.aland / 1e6)::numeric, 1)                                              AS area_km2,
    ROUND((c.aland / 2589988.11)::numeric, 1)                                       AS area_sq_mi,

    -- Population density
    -- ::numeric cast required: PostgreSQL has no ROUND(double precision, integer) overload.
    -- NULLIF guards against division by zero (uninhabited islands, water-only polygons).
    ROUND(s.total_pop::numeric / NULLIF((c.aland / 1e6)::numeric,        0), 1)    AS pop_per_km2,
    ROUND(s.total_pop::numeric / NULLIF((c.aland / 2589988.11)::numeric, 0), 1)    AS pop_per_sq_mi,

    -- County share of state population (%)
    ROUND(s.total_pop::numeric / NULLIF(sp.state_total_pop::numeric, 0) * 100, 2)  AS state_pop_share_pct

FROM   geom_src  c
JOIN   src       s  ON c.geoid  = s.geoid
JOIN   state_pop sp ON c.stusps = sp.stusps
WHERE  c.geoid = (SELECT target_geoid FROM params);


-- ============================================
-- [QUERY B] All counties in a state, ranked by population (uncomment to use)
-- ============================================
-- WITH params AS (
--     SELECT
--         'NY'     AS target_stusps,   -- state postal code
--         -- examples: 'NY' = New York (62 counties)
--         --           'TX' = Texas (254 counties — most of any state)
--         --           'CA' = California
--         'acs'    AS data_source,
--         2022     AS acs_year,
--         2020     AS dec_year
-- ),
-- geom_src AS (
--     SELECT geoid, name, namelsad, stusps, state_name, aland
--     FROM   admin_us.counties
--     WHERE  (SELECT data_source FROM params) = 'acs'
--     UNION ALL
--     SELECT geoid, name, namelsad, stusps, state_name, aland
--     FROM   admin_us.counties_2020
--     WHERE  (SELECT data_source FROM params) = 'decennial'
-- ),
-- src AS (
--     SELECT geoid, total_pop
--     FROM   census_us.acs_demographics
--     WHERE  survey_year = (SELECT acs_year FROM params)
--       AND  (SELECT data_source FROM params) = 'acs'
--     UNION ALL
--     SELECT geoid, total_pop
--     FROM   census_us.decennial_census
--     WHERE  census_year = (SELECT dec_year FROM params)
--       AND  (SELECT data_source FROM params) = 'decennial'
-- )
-- SELECT
--     c.geoid,
--     c.name                                                                          AS county_name,
--     c.namelsad                                                                      AS county_namelsad,
--     s.total_pop,
--     ROUND((c.aland / 1e6)::numeric, 1)                                              AS area_km2,
--     ROUND((c.aland / 2589988.11)::numeric, 1)                                       AS area_sq_mi,
--     ROUND(s.total_pop::numeric / NULLIF((c.aland / 1e6)::numeric,        0), 1)    AS pop_per_km2,
--     ROUND(s.total_pop::numeric / NULLIF((c.aland / 2589988.11)::numeric, 0), 1)    AS pop_per_sq_mi,
--     ROUND(s.total_pop::numeric / NULLIF(SUM(s.total_pop) OVER ()::numeric, 0) * 100, 2)
--                                                                                     AS state_pop_share_pct
-- FROM   geom_src  c
-- JOIN   src       s  ON c.geoid = s.geoid
-- WHERE  c.stusps = (SELECT target_stusps FROM params)
-- ORDER BY s.total_pop DESC NULLS LAST;


-- [NOTES]
-- · GEOID is a 5-digit string: first 2 digits = state FIPS, last 3 = county FIPS.
--   Example: '36061' → state 36 (NY) + county 061 (New York County).
--   A full FIPS table: https://www.census.gov/library/reference/code-lists/ansi.html
--
-- · state_pop_share_pct sums all counties in the same state.
--   For Connecticut in 'decennial' mode, the 8 legacy counties (TIGER/Line 2020) are
--   used; switching to 'acs' mode uses 9 planning regions — totals will match within
--   each vintage but differ across vintages.
--
-- · Independent cities in Virginia (e.g. Richmond, Alexandria) hold their own
--   GEOID entries and are counted separately from the surrounding county.
--   Their state_pop_share_pct is calculated correctly as long as they appear in
--   the geometry table.
--
-- · No rows returned?
--     → The GEOID may not exist in the selected vintage (e.g. a 2022 GEOID used
--       with data_source = 'decennial', or a Connecticut planning region GEOID
--       used with data_source = 'decennial').
--
-- · Why ::numeric cast on ROUND?
--     Columns imported via pandas/SQLAlchemy land as double precision.
--     PostgreSQL provides ROUND(numeric, integer) but not ROUND(double precision, integer).
--     Casting all operands to ::numeric resolves the "function round does not exist" error.
--
-- [EXAMPLES]
--   New York County (Manhattan)  GEOID 36061 → pop ~1,694,251 | ~27,544/km² | ~2.7% of NY state
--   Los Angeles County           GEOID 06037 → pop ~9,829,544 | ~   909/km² | ~25.0% of CA
--   Loving County TX             GEOID 48301 → pop ~        64 | <0.1/km²   | <0.01% of TX
