-- ============================================
-- [METADATA]
-- file       : 01-01_find_county_from_point.sql
-- category   : basic
-- tags       : #coordinate #county #geocoding #reverse-geocoding #tiger
-- difficulty : ★☆☆ (beginner)
-- estimated_complexity : low — single spatial predicate, sub-second on indexed geometry
-- execution_time : <1s
-- ============================================
-- purpose : Identify the county that contains a given coordinate (longitude, latitude).
-- input   : target_lon (longitude), target_lat (latitude)
-- output  : county name, full legal name (namelsad), GEOID (5-digit FIPS),
--           state abbreviation, state name, area (km²)
-- tables  : admin_us.counties
-- created : 2026-04-27
-- updated : 2026-04-27
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        -73.9856407 AS target_lon,   -- longitude  (example: Empire State Building)
         40.7483880 AS target_lat    -- latitude   (example: Empire State Building)
)
-- ============================================

-- [MAIN QUERY] No changes needed below this line
SELECT
    c.name                                    AS county_name,
    c.namelsad                                AS county_namelsad,
    c.geoid                                   AS geoid,
    c.stusps                                  AS state,
    c.state_name                              AS state_name,
    ROUND((c.aland / 1e6)::numeric, 2)        AS area_km2
FROM
    admin_us.counties c,
    params p
WHERE
    ST_Contains(
        c.geom,
        ST_SetSRID(ST_MakePoint(p.target_lon, p.target_lat), 4326)
    );

-- [NOTES]
-- · ST_Contains returns TRUE when the point lies strictly inside the polygon.
--   Points exactly on a boundary may return FALSE depending on floating-point
--   precision. Use ST_Intersects instead if you need to capture boundary cases.
--
-- · area_km2 is derived from the TIGER/Line `aland` field (land area in m²),
--   which excludes water bodies. This is more accurate than ST_Area() on the
--   cartographic boundary polygon.
--
-- · No rows returned?
--     → The coordinate may be in open water, outside the US, or in a data gap.
--       Independent cities in Virginia (e.g. Richmond, Alexandria) have their
--       own GEOID entries — they will match correctly.
--
-- · Multiple rows returned?
--     → Overlapping geometries exist in the boundary data. Inspect with:
--         SELECT geoid, name FROM admin_us.counties
--         WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint(-73.9856407, 40.7483880), 4326));
--
-- [EXAMPLES]
--   Empire State Building  (-73.9856407, 40.7483880) → New York County, NY  (GEOID 36061)
--   Willis Tower            (-87.6358,   41.8789)    → Cook County, IL       (GEOID 17031)
--   Space Needle            (-122.3493,  47.6205)    → King County, WA       (GEOID 53033)
