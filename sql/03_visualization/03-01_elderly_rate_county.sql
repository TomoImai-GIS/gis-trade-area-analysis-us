-- ============================================
-- [METADATA]
-- file       : 03-01_elderly_rate_county.sql
-- category   : visualization
-- tags       : #choropleth #elderly-rate #demographics #qgis #map #county
-- difficulty : ★☆☆ (beginner)
-- estimated_complexity : low — single join with filter, geometry included for QGIS
-- execution_time : <1s
-- ============================================
-- purpose : Export county-level elderly population and rate with geometry for
--           choropleth map rendering in QGIS.
--           Data source and coverage are controlled by the params block:
--             data_source  — 'acs' (ACS 5-year estimates) or 'decennial' (Decennial Census)
--             area_filter  — 'all' / 'contiguous' / '<STUSPS>'
--           Designed to be overlaid with the state boundary layer from admin_us.states.
--
-- IMPORTANT — Connecticut geometry mismatch (see [NOTES] for details):
--   data_source = 'acs'        → uses admin_us.counties      (TIGER/Line 2022, 9 planning regions)
--   data_source = 'decennial'  → uses admin_us.counties_2020 (TIGER/Line 2020, 8 legacy counties)
--   Requires admin_us.counties_2020 to be imported via 05-01_import_tiger_boundaries.py
--   with TARGET_YEAR=2020 and TABLE_COUNTIES='counties_2020' before running in decennial mode.
--
-- input   : data_source, acs_year, dec_year, area_filter — set in params block below
-- output  : county polygons with elderly rate and demographic breakdown —
--           load directly into QGIS as a PostGIS layer
-- tables  : admin_us.counties, admin_us.counties_2020,
--           census_us.acs_demographics, census_us.decennial_census
-- created : 2026-04-22
-- updated : 2026-04-23
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        'acs'        AS data_source,   -- 'acs'        → ACS 5-year estimates (census_us.acs_demographics)
                                       -- 'decennial'  → Decennial Census full count (census_us.decennial_census)
                                       --   Note: 'decennial' requires admin_us.counties_2020 (see above)
        2022         AS acs_year,      -- ACS vintage year        (used when data_source = 'acs')
        2020         AS dec_year,      -- Decennial Census year   (used when data_source = 'decennial')
        'contiguous' AS area_filter    -- 'all'        → all counties (national, including AK/HI/territories)
                                       -- 'contiguous' → 48 contiguous states only (excludes AK, HI, PR, VI, GU, AS, MP)
                                       -- '<STUSPS>'   → single state, e.g. 'FL'  'NY'  'TX'  'CA'
),
-- ============================================

-- Geometry abstraction: select county boundaries from the vintage-appropriate table.
--   ACS 2022    → admin_us.counties      (TIGER/Line 2022: CT has 9 planning regions)
--   Decennial 2020 → admin_us.counties_2020 (TIGER/Line 2020: CT has 8 legacy counties)
-- The UNION ALL trick ensures only one branch is evaluated based on data_source.
geom_src AS (
    SELECT geoid, name, namelsad, stusps, state_name, geom
    FROM   admin_us.counties
    WHERE  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    SELECT geoid, name, namelsad, stusps, state_name, geom
    FROM   admin_us.counties_2020
    WHERE  (SELECT data_source FROM params) = 'decennial'
),

-- Demographic data abstraction: select from ACS or Decennial based on data_source.
-- Column names are identical across both tables (by design), so UNION ALL works cleanly.
src AS (
    -- ACS branch
    SELECT geoid, total_pop,
           male_65_66,   male_67_69,   male_70_74,   male_75_79,   male_80_84,   male_85_over,
           female_65_66, female_67_69, female_70_74, female_75_79, female_80_84, female_85_over
    FROM   census_us.acs_demographics
    WHERE  survey_year = (SELECT acs_year FROM params)
      AND  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    -- Decennial branch
    SELECT geoid, total_pop,
           male_65_66,   male_67_69,   male_70_74,   male_75_79,   male_80_84,   male_85_over,
           female_65_66, female_67_69, female_70_74, female_75_79, female_80_84, female_85_over
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

    -- 65+ population: sum of all age buckets >= 65 (male + female)
    (  s.male_65_66   + s.male_67_69   + s.male_70_74   + s.male_75_79
     + s.male_80_84   + s.male_85_over
     + s.female_65_66 + s.female_67_69 + s.female_70_74 + s.female_75_79
     + s.female_80_84 + s.female_85_over
    )                                                           AS pop_elderly,

    -- Elderly rate (%)
    -- Both operands cast to numeric to satisfy ROUND(numeric, integer).
    -- (PostgreSQL has no ROUND(double precision, integer) overload.)
    -- NULLIF guards against division by zero; returns NULL for sentinel-value counties.
    ROUND(
        (  s.male_65_66   + s.male_67_69   + s.male_70_74   + s.male_75_79
         + s.male_80_84   + s.male_85_over
         + s.female_65_66 + s.female_67_69 + s.female_70_74 + s.female_75_79
         + s.female_80_84 + s.female_85_over
        )::numeric / NULLIF(s.total_pop::numeric, 0) * 100,
        1
    )                                                           AS elderly_rate,

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
-- · Connecticut geometry mismatch — why counties_2020 is needed
--     Connecticut abolished its 8 legacy counties as governmental units in 2022 and
--     replaced them with 9 Planning Regions. TIGER/Line 2022 reflects the new boundaries
--     (GEOIDs 09110–09190), while the 2020 Decennial Census API uses the old county FIPS
--     (GEOIDs 09001–09015). Joining TIGER/Line 2022 to Decennial 2020 on geoid therefore
--     produces no matches for any CT county, causing Connecticut to go blank on the map.
--     Using TIGER/Line 2020 (counties_2020) restores the correct join for Decennial data.
--
--     How to import admin_us.counties_2020:
--       1. Open python/05_data_import/05-01_import_tiger_boundaries.py
--       2. Change: TARGET_YEAR    = 2020
--                  TABLE_COUNTIES = 'counties_2020'
--       3. Run the script (TABLE_STATES can be left as 'states' or commented out)
--       4. Re-run this SQL with data_source = 'decennial'
--
-- · data_source switching
--     'acs'       : ACS 5-year pooled estimates; broader variable set; annual vintages.
--                   Uses admin_us.counties (TIGER/Line 2022).
--                   Sentinel values (-666666666 / -999999999) possible for very small counties.
--     'decennial' : Full enumeration (100% count); higher accuracy for small populations;
--                   no income/poverty variables. Available for 2020 only in this repo.
--                   Uses admin_us.counties_2020 (TIGER/Line 2020) to match CT legacy GEOIDs.
--     Both tables share identical column names (total_pop, male_65_66, etc.) by design,
--     enabling direct comparison via the src CTE without any column renaming.
--
-- · Why ROUND fails without ::numeric
--     Columns imported via pandas/SQLAlchemy are stored as double precision in PostgreSQL.
--     PostgreSQL provides ROUND(numeric, integer) but NOT ROUND(double precision, integer).
--     Casting both operands to ::numeric resolves this.
--
-- · Choropleth classification suggestion for elderly_rate (5 classes):
--     National median is approximately 20–22% as of 2022 ACS.
--     Natural breaks (Jenks) or quantile classification recommended in QGIS.
--
-- · 65+ age bucket composition:
--     ACS B01001 / Decennial P12 split the 65+ population into 6 fine-grained buckets per sex:
--       65–66, 67–69, 70–74, 75–79, 80–84, 85+
--     Summing all 12 (6 male + 6 female) gives the total elderly population.
--
-- [EXAMPLES]
--   ACS 2022, 48 contiguous states:
--     data_source = 'acs', acs_year = 2022, area_filter = 'contiguous'
--
--   Decennial 2020, 48 contiguous states (requires counties_2020):
--     data_source = 'decennial', dec_year = 2020, area_filter = 'contiguous'
--
--   ACS 2022, Florida only:
--     data_source = 'acs', acs_year = 2022, area_filter = 'FL'
--
--   Sort by highest elderly rate:
--     Change ORDER BY to: ORDER BY elderly_rate DESC NULLS LAST
-- ============================================
