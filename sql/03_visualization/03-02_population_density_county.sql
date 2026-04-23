-- ============================================
-- [METADATA]
-- file       : 03-02_population_density_county.sql
-- category   : visualization
-- tags       : #choropleth #population-density #demographics #qgis #map #county
-- difficulty : ★☆☆ (beginner)
-- estimated_complexity : low — single join with filter, geometry included for QGIS
-- execution_time : <1s
-- ============================================
-- purpose : Export county-level population density with geometry for
--           choropleth map rendering in QGIS.
--           Data source and coverage are controlled by the params block:
--             data_source  — 'acs' (ACS 5-year estimates) or 'decennial' (Decennial Census)
--             area_filter  — 'all' / 'contiguous' / '<STUSPS>'
--           Land area (aland) is sourced from the TIGER/Line geometry table,
--           which provides a more accurate area than ST_Area() on the
--           cb=True simplified polygon.
--           Designed to be overlaid with the state boundary layer from admin_us.states.
--
-- IMPORTANT — Connecticut geometry mismatch (see [NOTES] for details):
--   data_source = 'acs'        → uses admin_us.counties      (TIGER/Line 2022, 9 planning regions)
--   data_source = 'decennial'  → uses admin_us.counties_2020 (TIGER/Line 2020, 8 legacy counties)
--   Requires admin_us.counties_2020 before running in decennial mode.
--
-- input   : data_source, acs_year, dec_year, area_filter — set in params block below
-- output  : county polygons with population density for QGIS choropleth —
--           load directly into QGIS as a PostGIS layer
-- tables  : admin_us.counties, admin_us.counties_2020,
--           census_us.acs_demographics, census_us.decennial_census
-- created : 2026-04-23
-- updated : 2026-04-23
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        'acs'        AS data_source,   -- 'acs'        → ACS 5-year estimates (census_us.acs_demographics)
                                       -- 'decennial'  → Decennial Census full count (census_us.decennial_census)
                                       --   Note: 'decennial' requires admin_us.counties_2020
        2022         AS acs_year,      -- ACS vintage year        (used when data_source = 'acs')
        2020         AS dec_year,      -- Decennial Census year   (used when data_source = 'decennial')
        'contiguous' AS area_filter    -- 'all'        → all counties (national, including AK/HI/territories)
                                       -- 'contiguous' → 48 contiguous states only (excludes AK, HI, PR, VI, GU, AS, MP)
                                       -- '<STUSPS>'   → single state, e.g. 'FL'  'NY'  'TX'  'CA'
),
-- ============================================

-- Geometry abstraction: select county boundaries + aland from the vintage-appropriate table.
--   ACS 2022       → admin_us.counties      (TIGER/Line 2022)
--   Decennial 2020 → admin_us.counties_2020 (TIGER/Line 2020)
-- aland (land area in m²) is taken from the geometry table — more accurate than
-- ST_Area() on the cb=True simplified polygon.
geom_src AS (
    SELECT geoid, name, namelsad, stusps, state_name, aland, geom
    FROM   admin_us.counties
    WHERE  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    SELECT geoid, name, namelsad, stusps, state_name, aland, geom
    FROM   admin_us.counties_2020
    WHERE  (SELECT data_source FROM params) = 'decennial'
),

-- Demographic data abstraction: select total population from ACS or Decennial.
-- Column names are identical across both tables (by design), so UNION ALL works cleanly.
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
)

-- [MAIN QUERY] No changes needed below this line
SELECT
    c.geoid,
    c.name,
    c.namelsad,
    c.stusps,
    c.state_name,
    (SELECT data_source FROM params)                            AS data_source,
    s.total_pop,

    -- Land area (aland is stored in m²; convert to km² and sq mi for reference)
    ROUND((c.aland / 1e6)::numeric, 1)                         AS land_area_km2,
    ROUND((c.aland / 2589988.11)::numeric, 1)                  AS land_area_sq_mi,

    -- Population density
    -- Both operands cast to numeric to satisfy ROUND(numeric, integer).
    -- (PostgreSQL has no ROUND(double precision, integer) overload.)
    -- NULLIF guards against division by zero (uninhabited islands, etc.).
    ROUND(
        s.total_pop::numeric / NULLIF((c.aland / 1e6)::numeric, 0),
        1
    )                                                           AS pop_per_km2,

    ROUND(
        s.total_pop::numeric / NULLIF((c.aland / 2589988.11)::numeric, 0),
        1
    )                                                           AS pop_per_sq_mi,

    c.geom                                                      -- geometry for QGIS rendering

FROM  geom_src  c
JOIN  src       s  ON c.geoid = s.geoid

WHERE
    -- Coverage filter: controlled by params.area_filter
    CASE (SELECT area_filter FROM params)
        WHEN 'all'        THEN true
        WHEN 'contiguous' THEN c.stusps NOT IN ('AK', 'HI', 'PR', 'VI', 'GU', 'AS', 'MP')
        ELSE                   c.stusps = (SELECT area_filter FROM params)   -- single state by postal code
    END

    -- Exclude sentinel values (-666666666 / -999999999): unavailable for very small counties
    AND s.total_pop > 0

ORDER BY c.stusps, c.name;


-- ============================================
-- [NOTES]
-- · Load this query as a PostGIS layer in QGIS:
--     DB Manager → SQL Window → paste query → check "Load as new layer"
--     Set geometry column: geom  |  SRID: 4326
--
-- · Recommended overlay: state boundaries for visual reference
--     SQL: SELECT * FROM admin_us.states
--          WHERE stusps NOT IN ('AK', 'HI', 'PR', 'VI', 'GU', 'AS', 'MP')
--     Style: no fill, thin border (0.2–0.3px dark grey)
--
-- · Why aland from the geometry table (not ST_Area)?
--     cb=True (cartographic boundary) polygons are simplified for visualisation
--     and do not accurately represent true land area.
--     aland is pre-calculated by the Census Bureau from the full-resolution
--     TIGER/Line data and is far more accurate for density calculations.
--     aland is stored in square metres (m²); divide by 1e6 for km², by 2589988.11 for sq mi.
--
-- · Why aland, not (aland + awater)?
--     Population density is conventionally calculated over land area only.
--     Very high-water counties (e.g. island or lake counties) would show
--     artificially low density if water area were included.
--
-- · Connecticut geometry mismatch
--     Connecticut reorganised its 8 legacy counties into 9 Planning Regions in 2022.
--     'acs' mode uses TIGER/Line 2022 (new GEOIDs 09110–09190);
--     'decennial' mode uses TIGER/Line 2020 (old GEOIDs 09001–09015).
--     See docs/census_us_README.md § Known Issues for full details.
--
-- · Why ROUND fails without ::numeric
--     Columns imported via pandas/SQLAlchemy are stored as double precision in PostgreSQL.
--     PostgreSQL provides ROUND(numeric, integer) but NOT ROUND(double precision, integer).
--     Casting all operands to ::numeric resolves this.
--
-- · Choropleth classification suggestion for pop_per_km2 (5 classes):
--     US county densities range from < 0.1 (frontier counties) to > 27,000 (New York County).
--     Logarithmic scale or quantile classification strongly recommended in QGIS
--     to avoid most counties collapsing into the lowest class.
--     Alternatively, style by pop_per_sq_mi for US-standard reporting (1 sq mi ≈ 2.59 km²).
--
-- [EXAMPLES]
--   ACS 2022, 48 contiguous states:
--     data_source = 'acs', acs_year = 2022, area_filter = 'contiguous'
--
--   Decennial 2020, national (requires counties_2020):
--     data_source = 'decennial', dec_year = 2020, area_filter = 'all'
--
--   ACS 2022, Texas only:
--     data_source = 'acs', acs_year = 2022, area_filter = 'TX'
--
--   Sort by highest density:
--     Change ORDER BY to: ORDER BY pop_per_km2 DESC NULLS LAST
-- ============================================
