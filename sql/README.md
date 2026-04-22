# SQL Templates

Production-ready PostGIS SQL templates for spatial analysis and location intelligence work in the United States. Each template uses a `WITH params AS (...)` block at the top — edit the parameters and run.

> **Data prerequisites:** TIGER/Line boundaries in `admin_us` schema + Census data in `census_us` schema are required. See [Quick Start](../README.md#quick-start) and [`docs/census_us_README.md`](../docs/census_us_README.md) for setup instructions.

---

## Template Index

### 01_basic/ — Foundational spatial operations

| File | Purpose | Input | Output |
|------|---------|-------|--------|
| 01-01_find_county_from_point.sql | Reverse-geocode a coordinate to county | lon, lat | county name, GEOID, state | 🚧 planned |
| 01-02_calc_distance_between_points.sql | Straight-line distance between two coordinates | two lon/lat pairs | distance_km, distance_miles | 🚧 planned |

### 02_analysis/ — Core spatial analysis

| File | Purpose | Input | Output |
|------|---------|-------|--------|
| 02-01_calc_trade_area_population.sql | Aggregate population within a radius | center lon/lat, radius (m) | population, elderly rate, income — per county | 🚧 planned |
| 02-02_rank_counties_by_elderly_rate.sql | Rank counties by elderly population rate | state filter (optional) | ranked counties with demographic breakdown | 🚧 planned |

### 03_visualization/ — QGIS / map output queries

| File | Purpose | Output |
|------|---------|--------|
| [03-01_elderly_rate_county.sql](03_visualization/03-01_elderly_rate_county.sql) | County polygons with elderly rate for QGIS choropleth. Switchable between ACS 5-year and Decennial Census; parameterised coverage (all / contiguous / single state). | PostGIS layer (geom, SRID 4326) |

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

![Elderly rate choropleth — NY metro area](../output/sql/03-01_elderly_rate_county_zoomed.png)
*Zoomed view — New York metropolitan area*

**Design notes:**

- `data_source = 'acs'` uses `admin_us.counties` (TIGER/Line 2022) + `census_us.acs_demographics`
- `data_source = 'decennial'` uses `admin_us.counties_2020` (TIGER/Line 2020) + `census_us.decennial_census`
- The two-vintage geometry approach is required because Connecticut reorganised its 8 legacy counties into 9 Planning Regions in 2022, changing GEOIDs. See [Known Issues](../docs/census_us_README.md#6-known-issues).
- Both ACS and Decennial tables share identical column names by design, enabling the `src` CTE (UNION ALL) to switch data sources without any column renaming.

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
