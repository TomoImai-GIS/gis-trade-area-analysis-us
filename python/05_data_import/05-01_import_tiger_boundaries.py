"""
05-01_import_tiger_boundaries.py
Download TIGER/Line boundary shapefiles and import to PostGIS (admin_us schema)

Targets  : US States and Counties (national coverage)
Source   : US Census Bureau TIGER/Line via pygris (no API key required)
Output   : admin_us.states, admin_us.counties (PostGIS tables)

Coordinate system:
  TIGER/Line default is NAD83 (EPSG:4269).
  This script reprojects to WGS84 (EPSG:4326) to match the Japan portfolio convention.

Execution   : PyCharm or any standard Python environment (not QGIS)
Requirements: geopandas, pygris, sqlalchemy, GeoAlchemy2, psycopg2,
              AccessKeys/my_access.py
"""

import sys

import geopandas as gpd
import pygris
from sqlalchemy import create_engine, text

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
TARGET_DB   = 'gis'         # PostgreSQL database name
TARGET_YEAR = 2022          # TIGER/Line vintage year (use consistent year across scripts)
TARGET_CRS  = 4326          # Output CRS: WGS84 (matches Japan portfolio convention)

# Table names in admin_us schema
TABLE_STATES   = 'states'
TABLE_COUNTIES = 'counties'

# If_exists behaviour when writing to PostGIS:
#   'replace' — drop and recreate (safe for re-runs)
#   'append'  — add rows to existing table
IF_EXISTS = 'replace'

# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
engine = create_engine(
    f'postgresql+psycopg2://{ma.user}:{ma.password}@{ma.host}:{ma.port}/{TARGET_DB}'
)

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
def fetch_and_load(gdf: gpd.GeoDataFrame, table: str) -> None:
    """Reproject GeoDataFrame to TARGET_CRS and write to PostGIS."""
    gdf = gdf.to_crs(epsg=TARGET_CRS)
    gdf.columns = [c.lower() for c in gdf.columns]   # normalise column names to lowercase
    gdf.to_postgis(
        name=table,
        con=engine,
        schema='admin_us',
        if_exists=IF_EXISTS,
        index=False,
    )
    print(f'  → admin_us.{table}: {len(gdf):,} rows loaded.')


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:

    # ------------------------------------------------------------------
    # 1. States (50 states + DC + US territories)
    # ------------------------------------------------------------------
    print('Fetching States ...')
    states = pygris.states(year=TARGET_YEAR, cb=True)
    # cb=True  uses the cartographic boundary file (generalised, smaller file)
    # cb=False uses the full-resolution TIGER/Line file
    fetch_and_load(states, TABLE_STATES)

    # ------------------------------------------------------------------
    # 2. Counties (national, all states)
    # ------------------------------------------------------------------
    print('Fetching Counties ...')
    counties = pygris.counties(year=TARGET_YEAR, cb=True)
    fetch_and_load(counties, TABLE_COUNTIES)

    # ------------------------------------------------------------------
    # 3. Spatial index (recommended after bulk load)
    # ------------------------------------------------------------------
    print('Creating spatial indexes ...')
    with engine.connect() as conn:
        conn.execute(text(
            'CREATE INDEX IF NOT EXISTS idx_states_geom '
            'ON admin_us.states USING GIST (geometry)'
        ))
        conn.execute(text(
            'CREATE INDEX IF NOT EXISTS idx_counties_geom '
            'ON admin_us.counties USING GIST (geometry)'
        ))
        conn.commit()
    print('  → Spatial indexes created.')

    print('\nDone. Verify with:')
    print("  SELECT COUNT(*) FROM admin_us.states;    -- expect ~56 (50 states + DC + territories)")
    print("  SELECT COUNT(*) FROM admin_us.counties;  -- expect ~3,143")


if __name__ == '__main__':
    main()

# ---------------------------------------------------------------------------
# [NOTES]
# ---------------------------------------------------------------------------
# Key columns after import:
#
#   admin_us.states
#     statefp   : 2-digit FIPS code (e.g., '06' = California)
#     stusps    : 2-letter postal abbreviation (e.g., 'CA')
#     name      : full state name
#     geometry  : polygon (WGS84, EPSG:4326)
#
#   admin_us.counties
#     statefp   : 2-digit state FIPS code
#     countyfp  : 3-digit county FIPS code
#     geoid     : 5-digit unique national identifier = statefp + countyfp
#                 → equivalent to city_code in the Japan portfolio
#     name      : county name (without state)
#     namelsad  : full name including type (e.g., 'Los Angeles County')
#     geometry  : polygon (WGS84, EPSG:4326)
#
# cb=True vs cb=False:
#   cb=True  → cartographic boundary (generalised, ~10x smaller file, good for visualisation)
#   cb=False → full TIGER/Line resolution (precise boundaries, needed for exact point-in-polygon)
#   Change IF_EXISTS = 'replace' and re-run to switch between the two.
#
# Re-run behaviour:
#   IF_EXISTS = 'replace' drops and recreates the table on each run.
#   Switch to 'append' only when adding data for additional years.
#
# Troubleshooting:
#   ImportError: pygris not found → pip install pygris
#   GeoAlchemy2 not found        → pip install GeoAlchemy2
#   Connection refused           → check ma.host / ma.port in my_access.py
