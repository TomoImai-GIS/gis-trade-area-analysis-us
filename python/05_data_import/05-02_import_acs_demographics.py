"""
05-02_import_acs_demographics.py
Fetch ACS 5-year estimates from the Census API and import to PostgreSQL (census_us schema)

Targets  : County-level demographic data (national coverage)
Source   : US Census Bureau ACS 5-year estimates via census library (API key required)
Output   : census_us.acs_demographics

Design policy:
  All variables are stored as-is from the Census API — no derived columns.
  Aggregations and derived metrics (elderly_rate, poverty_rate, etc.)
  are intentionally left to SQL queries in sql/02_analysis/.
  This mirrors the Japan portfolio convention where e_stat tables store
  raw census values and views handle the derived logic.

Variables fetched:
  B01001 — Sex by Age (49 variables: total + male 23 buckets + female 23 buckets)
    _001E : total population (universe)
    _002E : male total
    _003E ~ _025E : male by age group (under 5 through 85+)
    _026E : female total
    _027E ~ _049E : female by age group (under 5 through 85+)
  B01002_001E — Median age
  B19013_001E — Median household income
  B17001_001E — Poverty status: universe (denominator)
  B17001_002E — Poverty status: below poverty level

Structural columns added by this script (not from API):
  geoid       : statefp + countyfp (5-digit, joins to admin_us.counties.geoid)
  survey_year : ACS vintage year (for multi-year table management)

Join example (SQL):
  SELECT c.name, c.geom, a.total_pop, a.median_hh_income
  FROM   admin_us.counties         c
  JOIN   census_us.acs_demographics a ON c.geoid = a.geoid
  WHERE  a.survey_year = 2022;

Execution   : PyCharm or any standard Python environment (not QGIS)
Requirements: census, pandas, sqlalchemy, psycopg2,
              AccessKeys/my_access.py
"""

import sys

import pandas as pd
from census import Census
from sqlalchemy import create_engine

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
# AccessKeys/my_access.py must be on the Python path.
# Adjust the path below to match your environment, or add it via IDE settings.
sys.path.append(r'C:\path\to\AccessKeys')   # ← edit before running
import my_access as ma

# ---------------------------------------------------------------------------
# Parameters  (edit here)
# ---------------------------------------------------------------------------
TARGET_DB       = 'gis'         # PostgreSQL database name
TARGET_YEAR     = 2022          # ACS 5-year vintage (use same year as 05-01 TIGER/Line)
PG_HOST         = 'localhost'   # PostgreSQL host (change if DB is on a remote server)
PG_PORT         = 5432          # PostgreSQL port (default: 5432)
CENSUS_API_KEY  = ma.census_api_key()   # ← define census_api_key() in my_access.py,
                                        #   or replace with key string directly

# Target table in census_us schema
TABLE_ACS = 'acs_demographics'

# If_exists behaviour when writing to PostgreSQL:
#   'replace' — drop and recreate (safe for re-runs)
#   'append'  — add rows to existing table (use for adding a new survey_year)
IF_EXISTS = 'replace'

# ---------------------------------------------------------------------------
# ACS variable definitions — B01001 full age breakdown (all 49 variables)
# ---------------------------------------------------------------------------
ACS_VARS = (
    'NAME',           # "Los Angeles County, California"

    # B01001: Sex by Age
    'B01001_001E',    # total population (universe)
    'B01001_002E',    # male: total
    'B01001_003E',    # male: under 5
    'B01001_004E',    # male: 5-9
    'B01001_005E',    # male: 10-14
    'B01001_006E',    # male: 15-17
    'B01001_007E',    # male: 18-19
    'B01001_008E',    # male: 20
    'B01001_009E',    # male: 21
    'B01001_010E',    # male: 22-24
    'B01001_011E',    # male: 25-29
    'B01001_012E',    # male: 30-34
    'B01001_013E',    # male: 35-39
    'B01001_014E',    # male: 40-44
    'B01001_015E',    # male: 45-49
    'B01001_016E',    # male: 50-54
    'B01001_017E',    # male: 55-59
    'B01001_018E',    # male: 60-61
    'B01001_019E',    # male: 62-64
    'B01001_020E',    # male: 65-66
    'B01001_021E',    # male: 67-69
    'B01001_022E',    # male: 70-74
    'B01001_023E',    # male: 75-79
    'B01001_024E',    # male: 80-84
    'B01001_025E',    # male: 85+
    'B01001_026E',    # female: total
    'B01001_027E',    # female: under 5
    'B01001_028E',    # female: 5-9
    'B01001_029E',    # female: 10-14
    'B01001_030E',    # female: 15-17
    'B01001_031E',    # female: 18-19
    'B01001_032E',    # female: 20
    'B01001_033E',    # female: 21
    'B01001_034E',    # female: 22-24
    'B01001_035E',    # female: 25-29
    'B01001_036E',    # female: 30-34
    'B01001_037E',    # female: 35-39
    'B01001_038E',    # female: 40-44
    'B01001_039E',    # female: 45-49
    'B01001_040E',    # female: 50-54
    'B01001_041E',    # female: 55-59
    'B01001_042E',    # female: 60-61
    'B01001_043E',    # female: 62-64
    'B01001_044E',    # female: 65-66
    'B01001_045E',    # female: 67-69
    'B01001_046E',    # female: 70-74
    'B01001_047E',    # female: 75-79
    'B01001_048E',    # female: 80-84
    'B01001_049E',    # female: 85+

    # B01002: Median Age
    'B01002_001E',    # median age (total)

    # B19013: Median Household Income
    'B19013_001E',    # median household income (USD)

    # B17001: Poverty Status
    'B17001_001E',    # poverty status: universe (denominator)
    'B17001_002E',    # poverty status: below poverty level
)

# ---------------------------------------------------------------------------
# Column rename map: Census variable codes → descriptive snake_case names
# ---------------------------------------------------------------------------
RENAME_MAP = {
    'NAME'        : 'name',
    'B01001_001E' : 'total_pop',
    'B01001_002E' : 'male_total',
    'B01001_003E' : 'male_under5',
    'B01001_004E' : 'male_5_9',
    'B01001_005E' : 'male_10_14',
    'B01001_006E' : 'male_15_17',
    'B01001_007E' : 'male_18_19',
    'B01001_008E' : 'male_20',
    'B01001_009E' : 'male_21',
    'B01001_010E' : 'male_22_24',
    'B01001_011E' : 'male_25_29',
    'B01001_012E' : 'male_30_34',
    'B01001_013E' : 'male_35_39',
    'B01001_014E' : 'male_40_44',
    'B01001_015E' : 'male_45_49',
    'B01001_016E' : 'male_50_54',
    'B01001_017E' : 'male_55_59',
    'B01001_018E' : 'male_60_61',
    'B01001_019E' : 'male_62_64',
    'B01001_020E' : 'male_65_66',
    'B01001_021E' : 'male_67_69',
    'B01001_022E' : 'male_70_74',
    'B01001_023E' : 'male_75_79',
    'B01001_024E' : 'male_80_84',
    'B01001_025E' : 'male_85_over',
    'B01001_026E' : 'female_total',
    'B01001_027E' : 'female_under5',
    'B01001_028E' : 'female_5_9',
    'B01001_029E' : 'female_10_14',
    'B01001_030E' : 'female_15_17',
    'B01001_031E' : 'female_18_19',
    'B01001_032E' : 'female_20',
    'B01001_033E' : 'female_21',
    'B01001_034E' : 'female_22_24',
    'B01001_035E' : 'female_25_29',
    'B01001_036E' : 'female_30_34',
    'B01001_037E' : 'female_35_39',
    'B01001_038E' : 'female_40_44',
    'B01001_039E' : 'female_45_49',
    'B01001_040E' : 'female_50_54',
    'B01001_041E' : 'female_55_59',
    'B01001_042E' : 'female_60_61',
    'B01001_043E' : 'female_62_64',
    'B01001_044E' : 'female_65_66',
    'B01001_045E' : 'female_67_69',
    'B01001_046E' : 'female_70_74',
    'B01001_047E' : 'female_75_79',
    'B01001_048E' : 'female_80_84',
    'B01001_049E' : 'female_85_over',
    'B01002_001E' : 'median_age',
    'B19013_001E' : 'median_hh_income',
    'B17001_001E' : 'poverty_universe',
    'B17001_002E' : 'below_poverty',
    'state'       : 'statefp',
    'county'      : 'countyfp',
}

# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
engine = create_engine(
    f'postgresql+psycopg2://{ma.pg_user()}:{ma.pg_pass()}@{PG_HOST}:{PG_PORT}/{TARGET_DB}'
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:

    # ------------------------------------------------------------------
    # 1. Fetch ACS 5-year data from Census API
    # ------------------------------------------------------------------
    print(f'Fetching ACS 5-year {TARGET_YEAR} data ...')
    c = Census(CENSUS_API_KEY, year=TARGET_YEAR)
    raw = c.acs5.get(
        ACS_VARS,
        {'for': 'county:*', 'in': 'state:*'}
    )
    print(f'  → {len(raw):,} records fetched.')

    # ------------------------------------------------------------------
    # 2. Build DataFrame, rename columns
    # ------------------------------------------------------------------
    df = pd.DataFrame(raw)
    df = df.rename(columns=RENAME_MAP)

    # ------------------------------------------------------------------
    # 3. Add structural columns
    # ------------------------------------------------------------------
    # geoid: 5-digit unique county identifier — joins to admin_us.counties.geoid
    df['geoid'] = df['statefp'] + df['countyfp']

    # survey_year: ACS vintage for multi-year table management
    df['survey_year'] = TARGET_YEAR

    # ------------------------------------------------------------------
    # 4. Convert numeric columns (Census API returns all values as strings)
    # ------------------------------------------------------------------
    skip_cols = {'geoid', 'statefp', 'countyfp', 'name', 'survey_year'}
    num_cols = [c for c in df.columns if c not in skip_cols]
    df[num_cols] = df[num_cols].apply(pd.to_numeric, errors='coerce')

    # ------------------------------------------------------------------
    # 5. Reorder: structural columns first, then data columns
    # ------------------------------------------------------------------
    structural = ['geoid', 'statefp', 'countyfp', 'name', 'survey_year']
    data_cols  = [c for c in df.columns if c not in structural]
    df = df[structural + data_cols]

    # ------------------------------------------------------------------
    # 6. Load to PostgreSQL
    # ------------------------------------------------------------------
    print(f'Loading to census_us.{TABLE_ACS} ...')
    df.to_sql(
        name=TABLE_ACS,
        con=engine,
        schema='census_us',
        if_exists=IF_EXISTS,
        index=False,
    )
    print(f'  → census_us.{TABLE_ACS}: {len(df):,} rows loaded.')

    print('\nDone. Verify with:')
    print(f'  SELECT COUNT(*) FROM census_us.{TABLE_ACS};')
    print(f'  SELECT geoid, name, total_pop, median_age, median_hh_income')
    print(f'    FROM census_us.{TABLE_ACS} LIMIT 5;')


if __name__ == '__main__':
    main()

# ---------------------------------------------------------------------------
# [NOTES]
# ---------------------------------------------------------------------------
# Sentinel values from the Census API:
#   -666666666 : data not available (e.g., very small counties)
#   -999999999 : data withheld
#   Negative values should be treated as NULL in SQL queries:
#     WHERE median_hh_income > 0
#
# ACS Margin of Error (MOE):
#   This script fetches estimates only (_E suffix).
#   MOE variables (_M suffix) are omitted.
#   For publication-quality analysis, add MOE variables to ACS_VARS and RENAME_MAP.
#
# Multi-year management:
#   survey_year column allows appending future ACS vintages.
#   Change IF_EXISTS = 'append' and TARGET_YEAR for subsequent years.
#   Primary key concept: (geoid, survey_year) should be unique.
#
# Troubleshooting:
#   ImportError: census not found  → pip install census
#   KeyError on API response       → verify CENSUS_API_KEY is valid
#   All values NULL                → TARGET_YEAR may not have data yet (try year - 1)
