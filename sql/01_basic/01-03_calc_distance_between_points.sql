-- ============================================
-- [METADATA]
-- file       : 01-03_calc_distance_between_points.sql
-- category   : basic
-- tags       : #distance #two-points #km #miles #geography #straight-line #great-circle
-- difficulty : ★☆☆ (beginner)
-- estimated_complexity : low — no table scan, pure coordinate calculation
-- execution_time : <1s
-- ============================================
-- purpose : Calculate the straight-line (great-circle) distance between
--           two coordinate pairs, returned in both km and miles.
--           Query B (commented out below) ranks counties by distance from
--           a base point to each county centroid.
-- input   : two lon/lat pairs (point1, point2)
-- output  : distance_km, distance_miles
-- tables  : none for Query A  /  admin_us.counties for Query B
-- created : 2026-04-30
-- updated : 2026-04-30
-- ============================================

-- [PARAMETERS] Edit this block only
-- ============================================
WITH params AS (
    SELECT
        -73.9856407 AS point1_lon,   -- longitude of point 1  (example: Empire State Building, NYC)
         40.7483880 AS point1_lat,   -- latitude  of point 1
        -77.0090    AS point2_lon,   -- longitude of point 2  (example: US Capitol, Washington DC)
         38.8899    AS point2_lat    -- latitude  of point 2
)
-- ============================================

-- [QUERY A] Straight-line distance between two points   No changes needed below this line
SELECT
    ROUND(
        ST_Distance(
            ST_SetSRID(ST_MakePoint(p.point1_lon, p.point1_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(p.point2_lon, p.point2_lat), 4326)::geography
        )::numeric / 1000,
    2) AS distance_km,
    ROUND(
        ST_Distance(
            ST_SetSRID(ST_MakePoint(p.point1_lon, p.point1_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(p.point2_lon, p.point2_lat), 4326)::geography
        )::numeric / 1609.344,
    2) AS distance_miles
FROM params p;


-- ============================================
-- [QUERY B] Distance from a base point to each county centroid, nearest first
--           (uncomment to use)
-- ============================================
-- WITH params AS (
--     SELECT
--         -73.9856407 AS base_lon,   -- longitude of the base point  (example: Empire State Building)
--          40.7483880 AS base_lat    -- latitude  of the base point
-- )
-- SELECT
--     c.geoid,
--     c.name                                                                    AS county_name,
--     c.namelsad                                                                AS county_namelsad,
--     c.stusps                                                                  AS state,
--     ROUND(
--         ST_Distance(
--             ST_Centroid(c.geom)::geography,
--             ST_SetSRID(ST_MakePoint(p.base_lon, p.base_lat), 4326)::geography
--         )::numeric / 1000,
--     2)                                                                        AS distance_to_centroid_km,
--     ROUND(
--         ST_Distance(
--             ST_Centroid(c.geom)::geography,
--             ST_SetSRID(ST_MakePoint(p.base_lon, p.base_lat), 4326)::geography
--         )::numeric / 1609.344,
--     2)                                                                        AS distance_to_centroid_miles
-- FROM
--     admin_us.counties c,
--     params p
-- ORDER BY
--     distance_to_centroid_km ASC
-- LIMIT 20;

-- [NOTES]
-- · Cast to ::geography to compute great-circle (spherical) distance in metres.
--   Without this cast, ST_Distance operates on raw degree values, which is
--   geometrically meaningless for distance calculations.
--
-- · ST_Distance(geography) always returns metres.
--     ÷ 1000      → kilometres
--     ÷ 1609.344  → statute miles  (1 mile = 1,609.344 m, exact by definition since 1959)
--
-- · This is straight-line (as-the-crow-flies) distance.
--   Road distance and travel time will differ, especially in mountainous or
--   coastal areas. For road distance, consider pgRouting or an external API
--   (e.g. Google Maps Distance Matrix, OSRM, Valhalla).
--
-- · Query B uses ST_Centroid on the county polygon, which may fall outside
--   the polygon for concave or crescent-shaped counties (e.g. some coastal counties).
--   Use ST_PointOnSurface instead if a guaranteed interior point is required.
--
-- [EXAMPLES] (straight-line)
--   Empire State Building → US Capitol (DC) : ~328 km  / ~204 miles
--   Empire State Building → Willis Tower (Chicago) : ~1,148 km / ~713 miles
--   Empire State Building → Space Needle (Seattle)  : ~3,866 km / ~2,402 miles
