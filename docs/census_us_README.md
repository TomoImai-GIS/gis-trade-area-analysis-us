# census_us — US Census Data Design

> Last updated: 2026-04-21
> Target database: `gis` (PostgreSQL + PostGIS)
> Schemas: `admin_us`, `census_us`

---

## 1. Purpose

This document describes the design for loading US Census Bureau data into PostgreSQL for use in GIS analysis, trade area analysis, and portfolio demonstration.

**Design principles:**

- **Full source traceability** — API endpoints, variable codes, and vintage years are all recorded
- **Normalized design for time-series comparison** — annual data managed with a `survey_year` / `census_year` key
- **As-is storage** — all variables stored exactly as returned by the Census API; no derived columns in import scripts
- **Separate tables for structurally different data** — TIGER/Line boundaries vs. ACS estimates vs. Decennial Census counts
- **Cross-table comparability** — `acs_demographics` and `decennial_census` share identical column names (e.g. `total_pop`, `male_under5`) to enable direct cross-table queries

---

## 2. Data Sources

### 2-1. TIGER/Line Shapefiles

| Item | Detail |
|------|--------|
| Dataset name | Cartographic Boundary Files (cb=True) |
| Provider | US Census Bureau, Geography Division |
| Vintage used | 2022 |
| Access method | `pygris` library (no API key required) |
| Terms of use | https://www.census.gov/about/policies/open-gov/open-data.html |
| API reference | https://pygris.readthedocs.io/ |

Target layers:

| Layer | pygris call | Row count | Notes |
|-------|------------|-----------|-------|
| States | `pygris.states(year=2022, cb=True)` | ~56 | 50 states + DC + US territories |
| Counties | `pygris.counties(year=2022, cb=True)` | ~3,235 | Includes Puerto Rico and other territories |

`cb=True` uses the cartographic boundary file (generalised, ~10× smaller than full TIGER/Line). Suitable for visualisation and demographic joins. Use `cb=False` for exact point-in-polygon operations.

### 2-2. ACS 5-Year Estimates

| Item | Detail |
|------|--------|
| Dataset name | American Community Survey 5-Year Estimates |
| Provider | US Census Bureau |
| Vintage used | 2022 (covers 2018–2022 pooled sample) |
| Access method | `census` library (`c.acs5.get()`), API key required |
| API key registration | https://api.census.gov/data/key_signup.html |
| Table reference | https://api.census.gov/data/2022/acs/acs5/variables.html |
| Terms of use | https://www.census.gov/about/policies/open-gov/open-data.html |

ACS methodology note: The 5-year estimates pool approximately 2.5% of addresses surveyed per year over 5 consecutive years (total ~12.5% sample). This is **not** a moving average — each vintage's sample is independently weighted to produce county-level estimates. Consecutive vintages overlap 4 of their 5 sample years, so year-over-year changes smaller than the margin of error should be treated cautiously.

Tables fetched:

| Table | Description | Variables |
|-------|-------------|-----------|
| B01001 | Sex by Age | _001E–_049E (49 variables: total + 23 male + 23 female age buckets) |
| B01002 | Median Age | _001E |
| B19013 | Median Household Income | _001E |
| B17001 | Poverty Status | _001E (universe) + _002E (below poverty level) |

### 2-3. Decennial Census — 2020 DHC

| Item | Detail |
|------|--------|
| Dataset name | Decennial Census 2020 DHC (Demographic and Housing Characteristics) |
| Provider | US Census Bureau |
| Survey date | April 1, 2020 |
| Publication date | 2023-05-25 (DHC release) |
| Access method | Direct HTTP request to Census API (dhc endpoint) |
| Endpoint | `https://api.census.gov/data/2020/dec/dhc` |
| API key required | Yes |
| Variable reference | https://api.census.gov/data/2020/dec/dhc/variables.html |
| Terms of use | https://www.census.gov/about/policies/open-gov/open-data.html |

Decennial Census methodology note: The 2020 Decennial Census is a full enumeration (100% count) of the US population. All values are actual counts, not estimates. It provides high accuracy for small areas where ACS sample sizes are insufficient, but covers far fewer variables than ACS. Income and poverty data are **not** available in the Decennial Census — use ACS for those.

> **Why not the `census` library for DHC?**
> The `census` library's support for the `dhc` endpoint varies by version. To avoid version-dependent failures, `05-03_import_decennial_census.py` fetches DHC data via direct `requests.get()` instead of the `census` library.

Table fetched:

| Table | Description | Variables |
|-------|-------------|-----------|
| P12 | Sex by Age | _001N–_049N (49 variables: total + 23 male + 23 female age buckets) |

---

## 3. Raw Data Structure

### 3-1. TIGER/Line Column Structure

After import via `pygris` and reprojection to WGS84 (EPSG:4326), all column names are lowercased and the geometry column is renamed from `geometry` to `geom`.

**`admin_us.states`** — all columns

| Column | Type | Notes |
|--------|------|-------|
| `statefp` | varchar | 2-digit state FIPS code (e.g. `'06'` = California) — **primary join key to counties** |
| `statens` | varchar | State ANSI/GNIS numeric code (e.g. `'01779778'`) — Census internal identifier, rarely used in analysis |
| `affgeoid` | varchar | American FactFinder geographic identifier (e.g. `'0400000US06'`) — long-form geoid used in some Census products |
| `geoid` | varchar | Same as `statefp` for states (2-digit) |
| `stusps` | varchar | 2-letter postal abbreviation (e.g. `'CA'`) — useful for display and labelling |
| `name` | varchar | Full state name (e.g. `'California'`) |
| `lsad` | varchar | Legal/Statistical Area Description code — `'00'` = State for all rows in this table |
| `aland` | bigint | **Land area in square metres** — use as denominator for population density; excludes water bodies |
| `awater` | bigint | Water area in square metres (lakes, rivers, coastal water within legal boundary) |
| `geom` | geometry(MultiPolygon, 4326) | State boundary polygon, WGS84 (EPSG:4326); reprojected from NAD83 by import script |

**`admin_us.counties`** — all columns

| Column | Type | Notes |
|--------|------|-------|
| `statefp` | varchar | 2-digit state FIPS code |
| `countyfp` | varchar | 3-digit county FIPS code (e.g. `'037'` = Los Angeles County) |
| `countyns` | varchar | County ANSI/GNIS numeric code — Census internal identifier, rarely used in analysis |
| `affgeoid` | varchar | American FactFinder geographic identifier (e.g. `'0500000US06037'`) |
| `geoid` | varchar | **5-digit unique national identifier = statefp + countyfp** (e.g. `'06037'`) — **primary join key to all census_us tables** |
| `name` | varchar | County name without type (e.g. `'Los Angeles'`) |
| `namelsad` | varchar | Full name including legal type (e.g. `'Los Angeles County'`) — use for display labels |
| `stusps` | varchar | 2-letter state postal abbreviation (e.g. `'CA'`) — convenience column; avoids joining to states table for state labels |
| `state_name` | varchar | Full state name (e.g. `'California'`) — same convenience purpose as `stusps` |
| `lsad` | varchar | Legal/Statistical Area Description code — indicates the county's legal type (see table below) |
| `aland` | bigint | **Land area in square metres** — **recommended denominator for population density calculations**; pre-calculated from full TIGER/Line data (more accurate than `ST_Area(geom)` on the cb=True simplified polygon) |
| `awater` | bigint | Water area in square metres — large values indicate counties with significant lakes or coastal water (e.g. island counties) |
| `geom` | geometry(MultiPolygon, 4326) | County boundary polygon, WGS84 (EPSG:4326) |

`lsad` values found in the counties table:

| `lsad` | Legal type | Examples |
|--------|-----------|---------|
| `'06'` | County | Most US counties |
| `'07'` | City and Borough | Alaska (e.g. Juneau City and Borough) |
| `'12'` | Municipality | Puerto Rico municipalities |
| `'13'` | Borough | Alaska (e.g. Matanuska-Susitna Borough) |
| `'15'` | Census Area | Alaska unorganised areas (e.g. Yukon-Koyukuk Census Area) |
| `'25'` | City | Independent cities (e.g. Baltimore City, MD) |
| `'37'` | District | District of Columbia |

> **Population density recipe using `aland`:**
> ```sql
> SELECT geoid, namelsad,
>        ROUND(aland / 1e6, 1)                                    AS land_area_km2,
>        ROUND(total_pop::numeric / NULLIF(aland / 1e6, 0), 1)   AS pop_per_km2
> FROM   admin_us.counties
> JOIN   census_us.acs_demographics USING (geoid)
> WHERE  survey_year = 2022;
> ```
> `aland / 1e6` converts m² → km². Use `/ 2589988.11` for square miles.

`geoid` is the primary join key between `admin_us.counties` and all `census_us` tables. It is equivalent to Japan's `city_code`.

### 3-2. ACS Variable Structure

The Census API returns all values as strings. The import script converts numeric columns via `pd.to_numeric(errors='coerce')`. The API also auto-appends a `GEO_ID` field (e.g. `'0500000US01001'`) that was not requested — this is explicitly dropped before loading.

ACS B01001 age bucket boundaries (identical between ACS and Decennial Census):

| ACS variable | Decennial variable | Column name | Age range |
|---|---|---|---|
| `B01001_001E` | `P12_001N` | `total_pop` | Total population |
| `B01001_002E` | `P12_002N` | `male_total` | Male total |
| `B01001_003E` | `P12_003N` | `male_under5` | Male: under 5 |
| `B01001_004E` | `P12_004N` | `male_5_9` | Male: 5–9 |
| `B01001_005E` | `P12_005N` | `male_10_14` | Male: 10–14 |
| `B01001_006E` | `P12_006N` | `male_15_17` | Male: 15–17 |
| `B01001_007E` | `P12_007N` | `male_18_19` | Male: 18–19 |
| `B01001_008E` | `P12_008N` | `male_20` | Male: 20 |
| `B01001_009E` | `P12_009N` | `male_21` | Male: 21 |
| `B01001_010E` | `P12_010N` | `male_22_24` | Male: 22–24 |
| `B01001_011E` | `P12_011N` | `male_25_29` | Male: 25–29 |
| `B01001_012E` | `P12_012N` | `male_30_34` | Male: 30–34 |
| `B01001_013E` | `P12_013N` | `male_35_39` | Male: 35–39 |
| `B01001_014E` | `P12_014N` | `male_40_44` | Male: 40–44 |
| `B01001_015E` | `P12_015N` | `male_45_49` | Male: 45–49 |
| `B01001_016E` | `P12_016N` | `male_50_54` | Male: 50–54 |
| `B01001_017E` | `P12_017N` | `male_55_59` | Male: 55–59 |
| `B01001_018E` | `P12_018N` | `male_60_61` | Male: 60–61 |
| `B01001_019E` | `P12_019N` | `male_62_64` | Male: 62–64 |
| `B01001_020E` | `P12_020N` | `male_65_66` | Male: 65–66 |
| `B01001_021E` | `P12_021N` | `male_67_69` | Male: 67–69 |
| `B01001_022E` | `P12_022N` | `male_70_74` | Male: 70–74 |
| `B01001_023E` | `P12_023N` | `male_75_79` | Male: 75–79 |
| `B01001_024E` | `P12_024N` | `male_80_84` | Male: 80–84 |
| `B01001_025E` | `P12_025N` | `male_85_over` | Male: 85+ |
| `B01001_026E` | `P12_026N` | `female_total` | Female total |
| `B01001_027E`–`B01001_049E` | `P12_027N`–`P12_049N` | `female_under5`–`female_85_over` | Female age buckets (same as male) |

Additional ACS-only columns:

| ACS variable | Column name | Notes |
|---|---|---|
| `B01002_001E` | `median_age` | Median age (total population) |
| `B19013_001E` | `median_hh_income` | Median household income (USD) |
| `B17001_001E` | `poverty_universe` | Poverty status universe (denominator for poverty rate) |
| `B17001_002E` | `below_poverty` | Population below poverty level |

### 3-3. Structural Columns Added by Import Scripts

The following columns are not returned by the Census API. They are constructed by the import scripts:

| Column | Table(s) | Construction | Notes |
|--------|----------|--------------|-------|
| `geoid` | both census tables | `statefp + countyfp` | 5-digit county identifier; primary join key to `admin_us.counties.geoid` |
| `survey_year` | `acs_demographics` | `= TARGET_YEAR` | ACS vintage year; allows multi-year append |
| `census_year` | `decennial_census` | `= CENSUS_YEAR` | Decennial Census year; allows multi-year append |

---

## 4. Schema & Table Design

### 4-1. Schema Overview

```
gis database
├── admin_us schema                  ← administrative boundaries (TIGER/Line)
│   ├── states                       ← US states + territories (PostGIS)
│   └── counties                     ← US counties (PostGIS) — primary join layer
│
└── census_us schema                 ← Census demographic data
    ├── acs_demographics             ← ACS 5-year estimates (multi-year, survey_year key)
    └── decennial_census             ← Decennial Census full counts (multi-year, census_year key)
```

Join key: `admin_us.counties.geoid` ↔ `census_us.acs_demographics.geoid` ↔ `census_us.decennial_census.geoid`

### 4-2. `admin_us.states` Table

Created by `05-01_import_tiger_boundaries.py` via `geopandas.GeoDataFrame.to_postgis()`.
Column types and geometry SRID are inferred automatically by GeoAlchemy2.

Key columns:

| Column | Type | Notes |
|--------|------|-------|
| `statefp` | varchar | 2-digit state FIPS code |
| `stusps` | varchar | 2-letter postal abbreviation |
| `name` | varchar | Full state name |
| `geom` | geometry(MultiPolygon, 4326) | WGS84 |

Spatial index: `idx_states_geom ON admin_us.states USING GIST (geom)`

### 4-3. `admin_us.counties` Table

Created by `05-01_import_tiger_boundaries.py`.

Key columns:

| Column | Type | Notes |
|--------|------|-------|
| `statefp` | varchar | 2-digit state FIPS code |
| `countyfp` | varchar | 3-digit county FIPS code |
| `geoid` | varchar | 5-digit unique identifier (statefp + countyfp) — **primary join key** |
| `name` | varchar | County name (e.g. `'Los Angeles'`) |
| `namelsad` | varchar | Full name with type (e.g. `'Los Angeles County'`) |
| `geom` | geometry(MultiPolygon, 4326) | WGS84 |

Spatial index: `idx_counties_geom ON admin_us.counties USING GIST (geom)`

### 4-4. `census_us.acs_demographics` Table

Created by `05-02_import_acs_demographics.py` via `pandas.DataFrame.to_sql()`.

```sql
-- Structural columns (key + identifiers)
geoid           varchar   -- 5-digit county identifier (PRIMARY JOIN KEY)
statefp         varchar   -- 2-digit state FIPS
countyfp        varchar   -- 3-digit county FIPS
name            varchar   -- "Los Angeles County, California"
survey_year     integer   -- ACS vintage year (2022, ...)

-- Population: Sex by Age (B01001)
total_pop       numeric   -- B01001_001E: total population
male_total      numeric   -- B01001_002E
male_under5     numeric   -- B01001_003E
male_5_9        numeric   -- B01001_004E
male_10_14      numeric   -- B01001_005E
male_15_17      numeric   -- B01001_006E
male_18_19      numeric   -- B01001_007E
male_20         numeric   -- B01001_008E
male_21         numeric   -- B01001_009E
male_22_24      numeric   -- B01001_010E
male_25_29      numeric   -- B01001_011E
male_30_34      numeric   -- B01001_012E
male_35_39      numeric   -- B01001_013E
male_40_44      numeric   -- B01001_014E
male_45_49      numeric   -- B01001_015E
male_50_54      numeric   -- B01001_016E
male_55_59      numeric   -- B01001_017E
male_60_61      numeric   -- B01001_018E
male_62_64      numeric   -- B01001_019E
male_65_66      numeric   -- B01001_020E
male_67_69      numeric   -- B01001_021E
male_70_74      numeric   -- B01001_022E
male_75_79      numeric   -- B01001_023E
male_80_84      numeric   -- B01001_024E
male_85_over    numeric   -- B01001_025E
female_total    numeric   -- B01001_026E
female_under5   numeric   -- B01001_027E
...             numeric   -- (same 23 buckets as male)
female_85_over  numeric   -- B01001_049E

-- Additional ACS variables
median_age         numeric   -- B01002_001E
median_hh_income   numeric   -- B19013_001E (USD; see sentinel values below)
poverty_universe   numeric   -- B17001_001E (denominator)
below_poverty      numeric   -- B17001_002E (numerator)
```

Effective primary key: `(geoid, survey_year)`

### 4-5. `census_us.decennial_census` Table

Created by `05-03_import_decennial_census.py` via `pandas.DataFrame.to_sql()`.

```sql
-- Structural columns
geoid           varchar   -- 5-digit county identifier (PRIMARY JOIN KEY)
statefp         varchar   -- 2-digit state FIPS
countyfp        varchar   -- 3-digit county FIPS
name            varchar   -- "Los Angeles County, California"
census_year     integer   -- Decennial Census year (2020, ...)

-- Population: Sex by Age (P12 DHC)
total_pop       numeric   -- P12_001N: total population (full count)
male_total      numeric   -- P12_002N
male_under5     numeric   -- P12_003N
male_5_9        numeric   -- P12_004N
...             numeric   -- (same 23 buckets as acs_demographics)
male_85_over    numeric   -- P12_025N
female_total    numeric   -- P12_026N
female_under5   numeric   -- P12_027N
...             numeric   -- (same 23 buckets as male)
female_85_over  numeric   -- P12_049N
```

Effective primary key: `(geoid, census_year)`

> **Note:** Column names in `decennial_census` are intentionally identical to `acs_demographics`
> (e.g. `total_pop`, `male_under5`) to allow direct column-level comparison.
> Distinguish tables by: `census_us.decennial_census.census_year`
>                     vs `census_us.acs_demographics.survey_year`

### 4-6. Join Examples

```sql
-- Basic: county boundaries + ACS demographics
SELECT  c.namelsad,
        c.geom,
        a.total_pop,
        a.median_hh_income
FROM    admin_us.counties         c
JOIN    census_us.acs_demographics a  ON c.geoid = a.geoid
WHERE   a.survey_year = 2022;

-- Cross-table comparison: ACS estimate vs. Decennial full count
SELECT  d.geoid,
        d.name,
        d.total_pop                AS dec_total_pop,
        a.total_pop                AS acs_total_pop,
        d.census_year,
        a.survey_year
FROM    census_us.decennial_census  d
JOIN    census_us.acs_demographics  a  ON d.geoid = a.geoid
WHERE   d.census_year = 2020
  AND   a.survey_year = 2022;

-- Derived metric (in SQL, not in import script): elderly rate
SELECT  geoid,
        name,
        (male_65_66 + male_67_69 + male_70_74 + male_75_79 + male_80_84 + male_85_over
       + female_65_66 + female_67_69 + female_70_74 + female_75_79 + female_80_84 + female_85_over
        )::numeric / NULLIF(total_pop, 0) * 100  AS elderly_rate_pct
FROM    census_us.acs_demographics
WHERE   survey_year = 2022
ORDER BY elderly_rate_pct DESC;
```

---

## 5. Data Status

| Table | Content | Rows | Loaded |
|-------|---------|------|--------|
| `admin_us.states` | TIGER/Line 2022 (cb=True), WGS84 | ~56 | 2026-04-21 |
| `admin_us.counties` | TIGER/Line 2022 (cb=True), WGS84 | ~3,235 | 2026-04-21 |
| `census_us.acs_demographics` | ACS 5-year 2022 (survey_year=2022) | ~3,221 | 2026-04-21 |
| `census_us.decennial_census` | Decennial Census 2020 DHC (census_year=2020) | ~3,221 | 2026-04-21 |

Row count note: County-level rows in census tables (~3,221) are fewer than TIGER/Line counties (~3,235) because some territories and minor outlying islands in TIGER/Line do not have corresponding Census API records.

---

## 6. Known Issues

| Item | Detail |
|------|--------|
| ACS sentinel values | The Census API returns `-666666666` (data not available) and `-999999999` (data withheld) for counties too small for reliable estimates. These are stored as-is. Filter with `WHERE median_hh_income > 0` in SQL queries. |
| ACS Margin of Error | This script fetches estimates only (`_E` suffix). MOE variables (`_M` suffix) are omitted. For publication-quality analysis, add MOE variables to `ACS_VARS` and `RENAME_MAP` in `05-02`. |
| GEO_ID stray column | The Census API auto-appends an unrequested `GEO_ID` field (e.g. `'0500000US01001'`) to all responses. Both `05-02` and `05-03` explicitly drop this field before loading to avoid a stray NULL column in PostgreSQL. |
| ACS vintage overlap | Consecutive ACS 5-year vintages share 4 of 5 sample years. Year-over-year changes smaller than the margin of error are not statistically meaningful. |
| 2010 Decennial Census | The 2010 Decennial uses the SF1 endpoint and different variable codes (`P012xxx` prefix vs. `P12_xxxN`). A separate script is recommended for 2010 due to these structural differences. `05-03` implements 2020 DHC only. |
| TIGER/Line vs. Census API count mismatch | TIGER/Line includes all territories (Puerto Rico, US Virgin Islands, etc.); some of these lack corresponding records in the Census API demographic tables. The ~14-row gap between `admin_us.counties` and `census_us.*` row counts is expected. |
| Decennial Census: no income/poverty | The 2020 DHC does not include income or poverty variables. Use `census_us.acs_demographics` for `median_hh_income` and `below_poverty`. |
