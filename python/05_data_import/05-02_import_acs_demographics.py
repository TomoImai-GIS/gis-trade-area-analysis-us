"""
05-02_import_acs_demographics.py
Fetch ACS 5-year estimates from the Census API and import to PostGIS (census_us schema)

Targets  : County-level demographic data (national coverage)
Source   : US Census Bureau ACS 5-year estimates via census library (API key required)
Output   : census_us.acs_demographics

Variables fetched:
  B01003_001E  Total population
  B01002_001E  Median age
  B19013_001E  Median household income
  B17001_001E  Poverty status universe (denominator)
  B17001_002E  Population below poverty level
  B01001_020E ~ B01001_025E  Male population 65+ (6 age buckets)
  B01001_044E ~ B01001_049E  Female population 65+ (6 age buckets)

Derived columns computed in script:
  pop_65_over   : sum of 12 age-bucket columns above
  elderly_rate  : pop_65_over / total_pop * 100  (mirrors Japan portfolio metric)
  poverty_rate  : below_poverty / poverty_universe * 100

Join key:
  geoid (5-digit) = state (2-digit) + county (3-digit)
  → joins to admin_us.counties.geoid

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
#   'append'  — add rows to existing table
IF_EXISTS = 'replace'

# ---------------------------------------------------------------------------
# ACS variable definitions
# ---------------------------------------------------------------------------
# Male 65+ age buckets: 65-66, 67-69, 70-74, 75-79, 80-84, 85+
MALE_65_VARS   = ['B01001_020E', 'B01001_021E', 'B01001_022E',
                  'B01001_023E', 'B01001_024E', 'B01001_025E']

# Female 65+ age buckets: 65-66, 67-69, 70-74, 75-79, 80-84, 85+
FEMALE_65_VARS = ['B01001_044E', 'B01001_045E', 'B01001_046E',
                  'B01001_047E', 'B01001_048E', 'B01001_049E']

ACS_VARS = (
    'NAME',           # County name (e.g., 'Los Angeles County, California')
    'B01003_001E',    # Total population
    'B01002_001E',    # Median age
    'B19013_001E',    # Median household income
    'B17001_001E',    # Poverty status: universe (denominator)
    'B17001_002E',    # Poverty status: below poverty level
    *MALE_65_VARS,
    *FEMALE_65_VARS,
)

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
    # 2. Build DataFrame and rename columns
    # ------------------------------------------------------------------
    df = pd.DataFrame(raw)

    df = df.rename(columns={
        'NAME'        : 'name',           # "Los Angeles County, California"
        'B01003_001E' : 'total_pop',
        'B01002_001E' : 'median_age',
        'B19013_001E' : 'median_hh_income',
        'B17001_001E' : 'poverty_universe',
        'B17001_002E' : 'below_poverty',
        'B01001_020E' : 'male_65_66',
        'B01001_021E' : 'male_67_69',
        'B01001_022E' : 'male_70_74',
        'B01001_023E' : 'male_75_79',
        'B01001_024E' : 'male_80_84',
        'B01001_025E' : 'male_85_over',
        'B01001_044E' : 'female_65_66',
        'B01001_045E' : 'female_67_69',
        'B01001_046E' : 'female_70_74',
        'B01001_047E' : 'female_75_79',
        'B01001_048E' : 'female_80_84',
        'B01001_049E' : 'female_85_over',
        'state'       : 'statefp',        # 2-digit FIPS (keep original name for clarity)
        'county'      : 'countyfp',       # 3-digit FIPS
    })

    # ------------------------------------------------------------------
    # 3. Create geoid and derived columns
    # ------------------------------------------------------------------

    # geoid: 5-digit unique county identifier — joins to admin_us.counties.geoid
    df['geoid'] = df['statefp'] + df['countyfp']

    # Convert numeric columns (API returns strings)
    numeric_cols = [
        'total_pop', 'median_age', 'median_hh_income',
        'poverty_universe', 'below_poverty',
        'male_65_66', 'male_67_69', 'male_70_74',
        'male_75_79', 'male_80_84', 'male_85_over',
        'female_65_66', 'female_67_69', 'female_70_74',
        'female_75_79', 'female_80_84', 'female_85_over',
    ]
    df[numeric_cols] = df[numeric_cols].apply(pd.to_numeric, errors='coerce')

    # pop_65_over: total population aged 65 and over
    age65_cols = [
        'male_65_66', 'male_67_69', 'male_70_74',
        'male_75_79', 'male_80_84', 'male_85_over',
        'female_65_66', 'female_67_69', 'female_70_74',
        'female_75_79', 'female_80_84', 'female_85_over',
    ]
    df['pop_65_over'] = df[age65_cols].sum(axis=1)

    # elderly_rate: % of population aged 65+ (mirrors Japan portfolio metric)
    df['elderly_rate'] = (
        df['pop_65_over'] / df['total_pop'] * 100
    ).round(2)

    # poverty_rate: % of population below poverty level
    df['poverty_rate'] = (
        df['below_poverty'] / df['poverty_universe'] * 100
    ).round(2)

    # survey_year: vintage year for multi-year management (mirrors Japan census design)
    df['survey_year'] = TARGET_YEAR

    # ------------------------------------------------------------------
    # 4. Reorder columns
    # ------------------------------------------------------------------
    col_order = [
        'geoid', 'statefp', 'countyfp', 'name', 'survey_year',
        'total_pop', 'median_age', 'median_hh_income',
        'poverty_universe', 'below_poverty', 'poverty_rate',
        'pop_65_over', 'elderly_rate',
        'male_65_66', 'male_67_69', 'male_70_74',
        'male_75_79', 'male_80_84', 'male_85_over',
        'female_65_66', 'female_67_69', 'female_70_74',
        'female_75_79', 'female_80_84', 'female_85_over',
    ]
    df = df[col_order]

    # ------------------------------------------------------------------
    # 5. Load to PostgreSQL
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
    print(f'  SELECT geoid, name, total_pop, elderly_rate, poverty_rate')
    print(f'    FROM census_us.{TABLE_ACS} ORDER BY elderly_rate DESC LIMIT 10;')


if __name__ == '__main__':
    main()

# ---------------------------------------------------------------------------
# [NOTES]
# ---------------------------------------------------------------------------
# Key columns after import:
#
#   geoid          : 5-digit unique county identifier (statefp + countyfp)
#                    → joins to admin_us.counties.geoid
#   statefp        : 2-digit state FIPS code
#   countyfp       : 3-digit county FIPS code
#   name           : full county name (e.g., 'Los Angeles County, California')
#   survey_year    : ACS vintage year (for multi-year table management)
#   total_pop      : total population
#   median_age     : median age
#   median_hh_income : median household income (USD); -666666666 = not available
#   poverty_rate   : % below poverty level (derived)
#   elderly_rate   : % aged 65+ (derived; mirrors Japan portfolio metric)
#
# Negative values (e.g., -666666666):
#   The Census API returns negative sentinel values when data is unavailable
#   (e.g., very small counties). Filter with WHERE total_pop > 0 AND median_hh_income > 0.
#
# ACS Margin of Error (MOE):
#   This script fetches estimates only (_E suffix). MOE variables (_M suffix)
#   are omitted for simplicity. For publication-quality analysis, fetch and
#   store MOE columns as well.
#
# Multi-year management:
#   survey_year column allows appending future ACS vintages (2023, 2024 ...).
#   Change IF_EXISTS = 'append' and TARGET_YEAR for subsequent years.
#
# Join example (SQL):
#   SELECT c.name, c.geom, a.total_pop, a.elderly_rate
#   FROM   admin_us.counties  c
#   JOIN   census_us.acs_demographics a ON c.geoid = a.geoid
#   WHERE  a.survey_year = 2022;
#
# Troubleshooting:
#   ImportError: census not found → pip install census
#   KeyError on API response      → check CENSUS_API_KEY is valid
#   All values NULL               → TARGET_YEAR may not have data yet (use year - 1)
