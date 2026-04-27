# SQL Templates

Production-ready PostGIS SQL templates for spatial analysis and location intelligence work in the United States. Each template uses a `WITH params AS (...)` block at the top — edit the parameters and run.

> **Data prerequisites:** TIGER/Line boundaries in `admin_us` schema + Census data in `census_us` schema are required. See [Quick Start](../README.md#quick-start) and [`docs/census_us_README.md`](../docs/census_us_README.md) for setup instructions.

---

## Template Index

### 01_basic/ — Foundational spatial operations

| File | Purpose | Input | Output |
|------|---------|-------|--------|
| [01-01_find_county_from_point.sql](01_basic/01-01_find_county_from_point.sql) | Reverse-geocode a coordinate to county | lon, lat | county name, GEOID, state, area_km2 |
| 01-02_calc_distance_between_points.sql | Straight-line distance between two coordinates | two lon/lat pairs | distance_km, distance_miles | 🚧 planned |

### 02_analysis/ — Core spatial analysis

| File | Purpose | Input | Output |
|------|---------|-------|--------|
| 02-01_calc_trade_area_population.sql | Aggregate population within a radius | center lon/lat, radius (m) | population, elderly rate, income — per county | 🚧 planned |
| 02-02_rank_counties_by_elderly_rate.sql | Rank counties by elderly population rate | state filter (optional) | ranked counties with demographic breakdown | 🚧 planned |
| [02-05_list_counties_along_route_from_gps_log.sql](02_analysis/02-05_list_counties_along_route_from_gps_log.sql) | List US counties along a GPS-logged route, in travel order, with route length per county and ACS demographics | record_id from gps_log, ACS survey_year | counties in travel order with route_length_in_county_km, distance_from_start_km, total_pop |

### 03_visualization/ — QGIS / map output queries

| File | Purpose | Output |
|------|---------|--------|
| [03-01_elderly_rate_county.sql](03_visualization/03-01_elderly_rate_county.sql) | County polygons with elderly rate for QGIS choropleth. Switchable between ACS 5-year and Decennial Census; parameterised coverage (all / contiguous / single state). | PostGIS layer (geom, SRID 4326) |
| [03-02_population_density_county.sql](03_visualization/03-02_population_density_county.sql) | County polygons with population density (persons/km² and persons/sq mi) for QGIS choropleth. Uses `aland` from TIGER/Line for accurate land area. Same data_source and area_filter params as 03-01. | PostGIS layer (geom, SRID 4326) |

---

## Use Cases

### 👴 Demographic & Aging Analysis

Map and rank counties by elderly population rate — useful for healthcare facility planning, senior services market research, and retirement community site selection.

```sql
-- 03-01_elderly_rate_county.sql
WITH params AS (
    SELECT
        'acs'        AS data_source,   -- 'acs' or 'decennial'
        2022         AS acs_year,      -- ACS vintage  (used when data_source = 'acs')
        2020         AS dec_year,      -- Census year   (used when data_source = 'decennial')
        'contiguous' AS area_filter    -- 'all' / 'contiguous' / 'FL' / 'NY' / 'TX' / ...
)
```

The query calculates `pop_elderly` (sum of all 12 age buckets ≥ 65) and `elderly_rate` (%) from the raw ACS B01001 or Decennial P12 age variables — no pre-computed columns are stored in the database.

![Elderly rate choropleth — contiguous US](../output/sql/03-01_elderly_rate_county_wide.png)
*Elderly rate by county (48 contiguous states, ACS 5-year 2022) — generated with 03-01_elderly_rate_county.sql + QGIS*

![Elderly rate choropleth — East Coast](../output/sql/03-01_elderly_rate_county_zoomed.png)
*Zoomed view — East Coast (Mid-Atlantic to New England)*

**Design notes:**

- `data_source = 'acs'` uses `admin_us.counties` (TIGER/Line 2022) + `census_us.acs_demographics`
- `data_source = 'decennial'` uses `admin_us.counties_2020` (TIGER/Line 2020) + `census_us.decennial_census`
- The two-vintage geometry approach is required because Connecticut reorganised its 8 legacy counties into 9 Planning Regions in 2022, changing GEOIDs. See [Known Issues](../docs/census_us_README.md#6-known-issues).
- Both ACS and Decennial tables share identical column names by design, enabling the `src` CTE (UNION ALL) to switch data sources without any column renaming.

---

### 📍 Population Density Analysis

Map county-level population concentration — useful for **retail site selection**, **logistics network planning**, and identifying urban/rural market segments.

```sql
-- 03-02_population_density_county.sql
WITH params AS (
    SELECT
        'acs'        AS data_source,   -- 'acs' or 'decennial'
        2022         AS acs_year,
        2020         AS dec_year,
        'contiguous' AS area_filter    -- 'all' / 'contiguous' / 'TX' / 'CA' / ...
)
```

Both `pop_per_km2` and `pop_per_sq_mi` are output. Land area is taken from the TIGER/Line `aland` field — more accurate than `ST_Area()` on the cb=True simplified polygon. Logarithmic or quantile classification is recommended in QGIS as US county densities span several orders of magnitude (< 0.1 to > 27,000 persons/km²).

![Population density choropleth — contiguous US](../output/sql/03-02_population_density_county_wide.png)
*Population density by county (48 contiguous states, ACS 5-year 2022) — generated with 03-02_population_density_county.sql + QGIS*

![Population density choropleth — East Coast](../output/sql/03-02_population_density_county_zoomed.png)
*Zoomed view — East Coast (Mid-Atlantic to New England). The density gradient from Manhattan outward to suburban and rural counties is clearly visible.*

**Design notes:**

- `aland` (land area in m²) is sourced from `geom_src` (the geometry table), not from the census table. Dividing by `1e6` converts to km²; dividing by `2589988.11` converts to sq mi.
- Same `geom_src` / `src` CTE structure as 03-01 — the Connecticut vintage mismatch is handled identically.

---

### 🗺️ Route Analysis — Counties Along a GPS Route

Identify which counties a route passes through, in travel order, with the distance driven through each county and ACS population data. Useful for **delivery route planning**, **logistics territory analysis**, and **field sales territory design**.

```sql
-- 02-05_list_counties_along_route_from_gps_log.sql
WITH params AS (
    SELECT
        384  AS target_record_id,  -- record_id from the gps_log table
        2022 AS survey_year        -- ACS vintage year
)
```

The query joins `admin_us.counties` against a LineString geometry stored in `gps_log`. Counties are sorted by travel order using `ST_LineLocatePoint` + `ST_LineSubstring`. Both km and mile columns are output for each distance measure:

| Output column | Description |
|---------------|-------------|
| `geoid` | 5-digit county FIPS (primary key) |
| `county_name` / `namelsad` | County name (short and long form) |
| `stusps` / `state_name` | State code and full name |
| `total_pop` | ACS total population |
| `route_length_in_county_km` / `_mi` | Distance driven within this county (km / miles) |
| `distance_from_start_km` / `_mi` | Distance from route start to county entry — sort key (km / miles) |

**Example route:**
Empire State Building, New York City → US Capitol, Washington DC
via I-95 southbound, switching to MD-295 at Baltimore
Passes through: NY → NJ → DE → MD → DC

![Counties along route — NYC to DC](../output/sql/02-05_list_counties_along_route_from_gps_log.png)
*Counties along route: Empire State Building → US Capitol via I-95 / MD-295. Highlighted counties in travel order; state boundaries overlaid from `admin_us.states`.*

**Customisation examples:**

```sql
-- Filter to specific states only
AND c.stusps IN ('NY', 'NJ', 'PA')

-- Add population density per county segment
ROUND(a.total_pop::numeric / NULLIF(c.aland / 1e6, 0)::numeric, 1) AS pop_per_km2

-- Analyse multiple routes at once
WHERE g.record_id IN (384, 385, 386) AND ST_Intersects(c.geom, g.geom)
-- (add record_id to ORDER BY for multi-route output)
```

> **Prerequisites:** `admin_us` and `census_us` are accessed as foreign tables via `postgres_fdw` from the DB containing `gps_log`. See the `[PREREQUISITES]` section in the SQL file for the 5-step setup. Required `gps_log` columns: `record_id INTEGER`, `geom GEOMETRY(LineString, 4326)`.

---

## Quick Start

### Prerequisites

- PostgreSQL 12+ with PostGIS 3.0+ enabled
- `admin_us.states`, `admin_us.counties`, `admin_us.counties_2020` loaded
- `census_us.acs_demographics` and/or `census_us.decennial_census` loaded

### 1. Enable PostGIS

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```

### 2. Load Census data

Run the Python import scripts in order:

```bash
python python/05_data_import/05-01_import_tiger_boundaries.py   # TIGER/Line 2022
# Re-run with TARGET_YEAR=2020, TABLE_COUNTIES='counties_2020'  # TIGER/Line 2020
python python/05_data_import/05-02_import_acs_demographics.py   # ACS 5-year
python python/05_data_import/05-03_import_decennial_census.py   # Decennial Census
```

### 3. Run in QGIS DB Manager

1. Open DB Manager → SQL Window
2. Paste the query
3. Check **Load as new layer**
4. Set geometry column: `geom` | SRID: `4326`
5. Overlay `admin_us.states` with no fill and a thin border for state boundaries

---

## Data Sources

| Dataset | Provider | Notes |
|---------|----------|-------|
| TIGER/Line 2020 & 2022 | [US Census Bureau](https://www.census.gov/geographies/mapping-files/time-series/geo/tiger-line-file.html) | States + Counties; cb=True (cartographic boundary) |
| ACS 5-year 2022 | [US Census Bureau ACS](https://www.census.gov/programs-surveys/acs) | B01001, B01002, B19013, B17001 |
| Decennial Census 2020 DHC | [US Census Bureau 2020 Census](https://www.census.gov/programs-surveys/decennial-census/decade/2020/2020-census-main.html) | P12 Sex by Age |

For full schema design, variable mappings, and known issues, see [`docs/census_us_README.md`](../docs/census_us_README.md).
