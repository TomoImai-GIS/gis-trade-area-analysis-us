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
-- input   : data_source, acs_year, dec_year, area_filter — set in params block below
-- output  : county polygons with elderly rate and demographic breakdown —
--           load directly into QGIS as a PostGIS layer
-- tables  : admin_us.counties, census_us.acs_demographics, census_us.decennial_census
-- created : 2026-04-22
-- updated : 2026-04-22
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        'acs'        AS data_source,   -- 'acs'        → ACS 5-year estimates (census_us.acs_demographics)
                                       -- 'decennial'  → Decennial Census full count (census_us.decennial_census)
        2022         AS acs_year,      -- ACS vintage year        (used when data_source = 'acs')
        2020         AS dec_year,      -- Decennial Census year   (used when data_source = 'decennial')
        'contiguous' AS area_filter    -- 'all'        → all counties (national, including AK/HI/territories)
                                       -- 'contiguous' → 48 contiguous states only (excludes AK, HI, PR, VI, GU, AS, MP)
                                       -- '<STUSPS>'   → single state, e.g. 'FL'  'NY'  'TX'  'CA'
),
-- ============================================

-- Source abstraction: select from ACS or Decennial based on data_source.
-- Column names are identical across both tables (by design), so UNION ALL works cleanly.
-- The WHERE clause on data_source ensures only one branch returns rows.
src AS (
    -- ACS branch
    SELECT geoid, total_pop,
           male_65_66,   male_67_69,   male_70_74,   male_75_79,   male_80_84,   male_85_over,
           female_65_66, female_67_69, female_70_74, female_75_79, female_80_84, female_85_over
    FROM   census_us.acs_demographics
    WHERE  survey_year = (SELECT acs_year    FROM params)
      AND  (SELECT data_source FROM params) = 'acs'

    UNION ALL

    -- Decennial branch
    SELECT geoid, total_pop,
           male_65_66,   male_67_69,   male_70_74,   male_75_79,   male_80_84,   male_85_over,
           female_65_66, female_67_69, female_70_74, female_75_79, female_80_84, female_85_over
    FROM   census_us.decennial_census
    WHERE  census_year = (SELECT dec_year    FROM params)
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

FROM  admin_us.counties  c
JOIN  src                s  ON c.geoid = s.geoid

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
-- · data_source switching
--     'acs'       : ACS 5-year pooled estimates; broader variable set; annual vintages.
--                   Sentinel values (-666666666 / -999999999) possible for very small counties.
--     'decennial' : Full enumeration (100% count); higher accuracy for small populations;
--                   no income/poverty variables. Available for 2020 only in this repo.
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
--   Decennial 2020, national:
--     data_source = 'decennial', dec_year = 2020, area_filter = 'all'
--
--   ACS 2022, Florida only:
--     data_source = 'acs', acs_year = 2022, area_filter = 'FL'
--
--   Sort by highest elderly rate:
--     Change ORDER BY to: ORDER BY elderly_rate DESC NULLS LAST
-- ============================================
