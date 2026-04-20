"""
05-03_import_decennial_census.py
Fetch Decennial Census data from the Census API and import to PostgreSQL (census_us schema)

Targets  : County-level population and age/sex data (national coverage)
Source   : US Census Bureau Decennial Census via census library (API key required)
Output   : census_us.decennial_census

Design policy:
  All variables stored as-is from the Census API — no derived columns.
  Aggregations and derived metrics are left to SQL queries in sql/02_analysis/.
  Use alongside census_us.acs_demographics:
    - Decennial Census : high accuracy, full count, limited variables
    - ACS 5-year       : annual updates, broad variables, sample-based

Census year availability:
  2020 : DHC (Demographic and Housing Characteristics) file — use dec/dhc endpoint
  2010 : SF1 (Summary File 1) — use sf1 endpoint
  Only the 2020 DHC is implemented below. For 2010, a separate script is recommended
  due to structural differences in variable codes.

Variables fetched (2020 DHC — P12: Sex by Age):
  P12_001N : total population
  P12_002N : male total
  P12_003N ~ P12_025N : male by age group (under 5 through 85+)
  P12_026N : female total
  P12_027N ~ P12_049N : female by age group (under 5 through 85+)

Structural columns added by this script (not from API):
  geoid       : statefp + countyfp (5-digit, joins to admin_us.counties.geoid)
  census_year : Decennial Census year (for multi-year table management)

Comparison with ACS acs_demographics table:
  - ACS B01001 uses _E suffix (estimates); Decennial P12 uses _N suffix (counts)
  - Age bucket boundaries are identical, enabling direct column-level comparison
  - Decennial total_pop is a full count; ACS total_pop is a weighted estimate

Join example (SQL):
  -- Compare elderly population: Decennial (accurate) vs ACS (recent)
  SELECT  d.geoid,
          d.total_pop                                AS dec_total_pop,
          a.total_pop                                AS acs_total_pop,
          d.census_year,
          a.survey_year
  FROM    census_us.decennial_census  d
  JOIN    census_us.acs_demographics  a  ON d.geoid = a.geoid
  WHERE   d.census_year = 2020
    AND   a.survey_year = 2022;

Execution   : PyCharm or any standard Python environment (not QGIS)
Requirements: census, pandas, sqlalchemy, psycopg2,
              AccessKeys/my_access.py
"""

import sys

import pandas as pd
from census import Census
from sqlalchemy import create_engine, inspect, text

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
CENSUS_YEAR     = 2020          # Decennial Census year (2020 or 2010)
                                # Note: 2010 requires different variable codes (SF1)
PG_HOST         = 'localhost'   # PostgreSQL host (change if DB is on a remote server)
PG_PORT         = 5432          # PostgreSQL port (default: 5432)
CENSUS_API_KEY  = ma.census_api_key()   # ← define census_api_key() in my_access.py,
                                        #   or replace with key string directly

# Target table in census_us schema
TABLE_DEC = 'decennial_census'

# If_exists behaviour when writing to PostgreSQL:
#   'replace' — drop and recreate (safe for re-runs)
#   'append'  — add rows to existing table (use for adding a new census_year)
IF_EXISTS = 'replace'

# ---------------------------------------------------------------------------
# Variable definitions — 2020 DHC P12: Sex by Age (49 variables)
# ---------------------------------------------------------------------------
DEC_VARS = (
    'NAME',         # "Los Angeles County, California"

    # P12: Sex by Age (2020 DHC)
    'P12_001N',     # total population
    'P12_002N',     # male: total
    'P12_003N',     # male: under 5
    'P12_004N',     # male: 5-9
    'P12_005N',     # male: 10-14
    'P12_006N',     # male: 15-17
    'P12_007N',     # male: 18-19
    'P12_008N',     # male: 20
    'P12_009N',     # male: 21
    'P12_010N',     # male: 22-24
    'P12_011N',     # male: 25-29
    'P12_012N',     # male: 30-34
    'P12_013N',     # male: 35-39
    'P12_014N',     # male: 40-44
    'P12_015N',     # male: 45-49
    'P12_016N',     # male: 50-54
    'P12_017N',     # male: 55-59
    'P12_018N',     # male: 60-61
    'P12_019N',     # male: 62-64
    'P12_020N',     # male: 65-66
    'P12_021N',     # male: 67-69
    'P12_022N',     # male: 70-74
    'P12_023N',     # male: 75-79
    'P12_024N',     # male: 80-84
    'P12_025N',     # male: 85+
    'P12_026N',     # female: total
    'P12_027N',     # female: under 5
    'P12_028N',     # female: 5-9
    'P12_029N',     # female: 10-14
    'P12_030N',     # female: 15-17
    'P12_031N',     # female: 18-19
    'P12_032N',     # female: 20
    'P12_033N',     # female: 21
    'P12_034N',     # female: 22-24
    'P12_035N',     # female: 25-29
    'P12_036N',     # female: 30-34
    'P12_037N',     # female: 35-39
    'P12_038N',     # female: 40-44
    'P12_039N',     # female: 45-49
    'P12_040N',     # female: 50-54
    'P12_041N',     # female: 55-59
    'P12_042N',     # female: 60-61
    'P12_043N',     # female: 62-64
    'P12_044N',     # female: 65-66
    'P12_045N',     # female: 67-69
    'P12_046N',     # female: 70-74
    'P12_047N',     # female: 75-79
    'P12_048N',     # female: 80-84
    'P12_049N',     # female: 85+
)

# ---------------------------------------------------------------------------
# Column rename map: Census variable codes → descriptive snake_case names
# (mirrors ACS acs_demographics column names for easy cross-table comparison)
# ---------------------------------------------------------------------------
RENAME_MAP = {
    'NAME'      : 'name',
    'P12_001N'  : 'total_pop',
    'P12_002N'  : 'male_total',
    'P12_003N'  : 'male_under5',
    'P12_004N'  : 'male_5_9',
    'P12_005N'  : 'male_10_14',
    'P12_006N'  : 'male_15_17',
    'P12_007N'  : 'male_18_19',
    'P12_008N'  : 'male_20',
    'P12_009N'  : 'male_21',
    'P12_010N'  : 'male_22_24',
    'P12_011N'  : 'male_25_29',
    'P12_012N'  : 'male_30_34',
    'P12_013N'  : 'male_35_39',
    'P12_014N'  : 'male_40_44',
    'P12_015N'  : 'male_45_49',
    'P12_016N'  : 'male_50_54',
    'P12_017N'  : 'male_55_59',
    'P12_018N'  : 'male_60_61',
    'P12_019N'  : 'male_62_64',
    'P12_020N'  : 'male_65_66',
    'P12_021N'  : 'male_67_69',
    'P12_022N'  : 'male_70_74',
    'P12_023N'  : 'male_75_79',
    'P12_024N'  : 'male_80_84',
    'P12_025N'  : 'male_85_over',
    'P12_026N'  : 'female_total',
    'P12_027N'  : 'female_under5',
    'P12_028N'  : 'female_5_9',
    'P12_029N'  : 'female_10_14',
    'P12_030N'  : 'female_15_17',
    'P12_031N'  : 'female_18_19',
    'P12_032N'  : 'female_20',
    'P12_033N'  : 'female_21',
    'P12_034N'  : 'female_22_24',
    'P12_035N'  : 'female_25_29',
    'P12_036N'  : 'female_30_34',
    'P12_037N'  : 'female_35_39',
    'P12_038N'  : 'female_40_44',
    'P12_039N'  : 'female_45_49',
    'P12_040N'  : 'female_50_54',
    'P12_041N'  : 'female_55_59',
    'P12_042N'  : 'female_60_61',
    'P12_043N'  : 'female_62_64',
    'P12_044N'  : 'female_65_66',
    'P12_045N'  : 'female_67_69',
    'P12_046N'  : 'female_70_74',
    'P12_047N'  : 'female_75_79',
    'P12_048N'  : 'female_80_84',
    'P12_049N'  : 'female_85_over',
    'state'     : 'statefp',
    'county'    : 'countyfp',
}

# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
engine = create_engine(
    f'postgresql+psycopg2://{ma.pg_user()}:{ma.pg_pass()}@{PG_HOST}:{PG_PORT}/{TARGET_DB}'
)

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
def already_imported(year: int) -> bool:
    """Return True if data for census_year already exists in the target table."""
    insp = inspect(engine)
    if not insp.has_table(TABLE_DEC, schema='census_us'):
        return False   # table does not exist yet — first run
    with engine.connect() as conn:
        result = conn.execute(
            text(f'SELECT COUNT(*) FROM census_us.{TABLE_DEC} WHERE census_year = :year'),
            {'year': year}
        )
        return result.scalar() > 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:

    # ------------------------------------------------------------------
    # 0. Duplicate check
    # ------------------------------------------------------------------
    if already_imported(CENSUS_YEAR):
        print(f'[ABORTED] census_year={CENSUS_YEAR} is already loaded in '
              f'census_us.{TABLE_DEC}.')
        print('  → To overwrite: set IF_EXISTS = "replace" and re-run.')
        print('  → To add a new year: change CENSUS_YEAR.')
        return

    # ------------------------------------------------------------------
    # 1. Fetch Decennial Census data from Census API
    # ------------------------------------------------------------------
    print(f'Fetching Decennial Census {CENSUS_YEAR} data ...')
    c = Census(CENSUS_API_KEY, year=CENSUS_YEAR)
    raw = c.dhc.get(
        DEC_VARS,
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

    # census_year: Decennial Census year for multi-year table management
    df['census_year'] = CENSUS_YEAR

    # ------------------------------------------------------------------
    # 4. Convert numeric columns (Census API returns all values as strings)
    # ------------------------------------------------------------------
    skip_cols = {'geoid', 'statefp', 'countyfp', 'name', 'census_year'}
    num_cols = [c for c in df.columns if c not in skip_cols]
    df[num_cols] = df[num_cols].apply(pd.to_numeric, errors='coerce')

    # ------------------------------------------------------------------
    # 5. Reorder: structural columns first, then data columns
    # ------------------------------------------------------------------
    structural = ['geoid', 'statefp', 'countyfp', 'name', 'census_year']
    data_cols  = [c for c in df.columns if c not in structural]
    df = df[structural + data_cols]

    # ------------------------------------------------------------------
    # 6. Load to PostgreSQL
    # ------------------------------------------------------------------
    print(f'Loading to census_us.{TABLE_DEC} ...')
    df.to_sql(
        name=TABLE_DEC,
        con=engine,
        schema='census_us',
        if_exists=IF_EXISTS,
        index=False,
    )
    print(f'  → census_us.{TABLE_DEC}: {len(df):,} rows loaded.')

    print('\nDone. Verify with:')
    print(f'  SELECT COUNT(*) FROM census_us.{TABLE_DEC};')
    print(f'  SELECT geoid, name, total_pop FROM census_us.{TABLE_DEC} LIMIT 5;')


if __name__ == '__main__':
    main()

# ---------------------------------------------------------------------------
# [NOTES]
# ---------------------------------------------------------------------------
# Column naming mirrors acs_demographics for cross-table comparability:
#   Both tables use identical column names (total_pop, male_under5, etc.)
#   Distinguish by: census_us.decennial_census.census_year
#                vs census_us.acs_demographics.survey_year
#
# 2020 vs 2010 differences:
#   2020 DHC : endpoint = c.dhc, variable prefix = P12_xxxN
#   2010 SF1 : endpoint = c.sf1, variable prefix = P012xxx
#   Due to these structural differences, a separate script is recommended for 2010.
#
# Income / poverty data:
#   The Decennial Census does NOT include income or poverty variables.
#   Use census_us.acs_demographics for median_hh_income and below_poverty.
#
# Troubleshooting:
#   AttributeError: Census has no attribute 'dhc'
#     → pip install --upgrade census  (dhc endpoint requires census >= 0.8.19)
#   KeyError on API response
#     → verify CENSUS_API_KEY is valid and CENSUS_YEAR=2020
