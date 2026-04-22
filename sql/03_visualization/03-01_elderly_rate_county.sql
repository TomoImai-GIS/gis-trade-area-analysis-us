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
--           Covers the 48 contiguous US states only (AK, HI, and territories excluded).
--           Designed to be overlaid with the state boundary layer from admin_us.states.
-- input   : survey_year (ACS vintage) — set in params block below
-- output  : county polygons with elderly rate and demographic breakdown —
--           load directly into QGIS as a PostGIS layer
-- tables  : admin_us.counties, census_us.acs_demographics
-- created : 2026-04-22
-- updated : 2026-04-22
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        2022 AS survey_year     -- ACS 5-year vintage year (match the imported year in census_us.acs_demographics)
)
-- ============================================

-- [MAIN QUERY] No changes needed below this line
SELECT
    c.geoid,
    c.name,
    c.namelsad,
    c.stusps,
    c.state_name,
    a.total_pop,

    -- 65+ population: sum of all age buckets >= 65 (male + female)
    (  a.male_65_66   + a.male_67_69   + a.male_70_74   + a.male_75_79
     + a.male_80_84   + a.male_85_over
     + a.female_65_66 + a.female_67_69 + a.female_70_74 + a.female_75_79
     + a.female_80_84 + a.female_85_over
    )                                                           AS pop_elderly,

    -- Elderly rate (%) — NULL-safe; returns NULL for counties with total_pop = 0 or sentinel values
    ROUND(
        (  a.male_65_66   + a.male_67_69   + a.male_70_74   + a.male_75_79
         + a.male_80_84   + a.male_85_over
         + a.female_65_66 + a.female_67_69 + a.female_70_74 + a.female_75_79
         + a.female_80_84 + a.female_85_over
        )::numeric / NULLIF(a.total_pop, 0) * 100,
        1
    )                                                           AS elderly_rate,

    c.geom                                                      -- geometry for QGIS rendering

FROM  admin_us.counties         c
JOIN  census_us.acs_demographics a
      ON  c.geoid      = a.geoid
      AND a.survey_year = (SELECT survey_year FROM params)

-- Contiguous US only: exclude Alaska, Hawaii, and all non-state territories
WHERE c.stusps NOT IN ('AK', 'HI', 'PR', 'VI', 'GU', 'AS', 'MP')

  -- Exclude counties with ACS sentinel values (data unavailable for very small populations)
  AND a.total_pop > 0

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
-- · Choropleth classification suggestion for elderly_rate (5 classes, quantile):
--     National median is approximately 20–22% as of 2022 ACS.
--     Natural breaks (Jenks) or quantile classification recommended in QGIS.
--
-- · ACS sentinel values:
--     The Census API returns -666666666 (not available) or -999999999 (withheld)
--     for very small counties. The WHERE total_pop > 0 filter removes these rows.
--     Affected counties are mainly in remote Alaska — already excluded by the
--     contiguous-US filter above.
--
-- · 65+ age bucket composition:
--     ACS B01001 splits the 65+ population into 6 fine-grained buckets per sex:
--       65–66, 67–69, 70–74, 75–79, 80–84, 85+
--     Summing all 12 (6 male + 6 female) gives the total elderly population.
--     These are estimates (_E suffix); no Margin of Error is included in this query.
--
-- · For Decennial Census comparison (full count vs. ACS estimate):
--     Replace census_us.acs_demographics with census_us.decennial_census
--     and change survey_year → census_year = 2020.
--     Column names (total_pop, male_65_66, etc.) are identical between the two tables.
--
-- [EXAMPLES]
--   Single state (e.g. Florida only):
--     Add to WHERE: AND c.stusps = 'FL'
--
--   Sort by highest elderly rate:
--     Change ORDER BY to: ORDER BY elderly_rate DESC NULLS LAST
-- ============================================
