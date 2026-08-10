"""
load_new_data.py
=================
Run this whenever a new data drop arrives. Handles all 8 datasets
correctly according to what KIND of data each one is — this is the
single most important distinction in this whole automation:
 
  SNAPSHOT tables (mobo25_stock, mm_minmax, ms_item_setup,
  mdb_item_master, si_site, cd_country, cx_currency_exchange):
  represent "right now" — the new file REPLACES the old one entirely.
 
  APPEND-ONLY table (mobo15_movements): a growing transaction history —
  new rows are ADDED to what's already there, never replacing it.
  Getting this backwards for mobo15_movements would silently destroy
  transaction history and break every year-over-year and trailing-12mo
  calculation in the project.
 
Accepts BOTH .csv and .xlsx files interchangeably — for each table,
the script looks for either extension in the drop folder and reads
whichever one it finds, so you don't need to convert Excel exports
to CSV by hand before running this.
 
USAGE
-----
    python load_new_data.py /path/to/2026-09-01/
 
Expects the folder to contain the day's files, named to match
SOURCE_FILES below (edit the mapping if your filenames differ) —
either as .csv or .xlsx, whichever you were sent.
 
WHAT IT DOES, IN ORDER
-----------------------
1. Archives nothing itself — you're expected to keep each drop in its
   own dated folder (see the folder convention below); this script
   only reads from wherever you point it.
2. Loads each snapshot table with TRUNCATE + fresh load.
3. Loads mobo15_movements by staging new rows, then inserting only
   the ones that aren't already present (deduplicated on a chosen key
   column — default: item_document).
4. Runs a row-count parity check: source file rows vs. loaded table
   rows, for every table.
5. Runs v_data_quality_flags and v_currency_coverage_gap and reports
   anything found — duplicate rows, missing FX rates, orphan site
   codes, unparseable dates.
6. Writes a timestamped log entry to load_history.log so there's an
   audit trail of every load, not just the most recent one.
 
RECOMMENDED FOLDER CONVENTION (keep every drop, never overwrite)
------------------------------------------------------------------
    /procurement_data/
      raw/
        2026-08-04/   <- first drop, untouched forever
        2026-09-01/   <- second drop, untouched forever
        ...
 
BEFORE RUNNING FOR REAL
------------------------
Fill in DB_CONNECTION_STRING below. Install dependencies once:
    pip install pandas sqlalchemy pymysql openpyxl --break-system-packages
"""
import sys
import csv
import re
import unicodedata
import logging
from pathlib import Path
from datetime import datetime
 
import pandas as pd
from sqlalchemy import create_engine, text
 
# =====================================================================
# TEXT/ID CLEANING — merged from clean_mobo.py, run automatically as
# step 1 of loading MOBO15/MOBO25, so nobody has to remember to run a
# separate cleaning script before this one. Logic is unchanged from
# the original clean_mobo.py; only the plumbing (operating on pandas
# Series instead of raw csv.DictReader rows) is different.
# =====================================================================
 
# Text that is really UTF-8 but got decoded once as Windows-1252/Latin-1
# and re-saved as UTF-8 shows up as garbled multi-byte sequences (â€™,
# Ã©, etc). Round-tripping through latin1 -> utf-8 fixes the common
# cases without touching text that's already correct.
MOJIBAKE_MARKERS = ("â€", "Ã¢", "Ã©", "Ã¯", "Ã¼", "Â")
WS_RE = re.compile(r"[ \t\u00a0]+")   # tabs / non-breaking spaces collapse into a single space
NEWLINE_RE = re.compile(r"[\r\n]+")
FLOAT_SUFFIX_RE = re.compile(r"^(-?\d+)\.0$")
 
# Which tables need the deeper text-hygiene pass (mojibake, whitespace,
# ID float-suffix), and which of their columns. Matches the original
# clean_mobo.py's scope — only MOBO15/MOBO25 had these issues found on
# inspection. Extend this if a future extract from another table shows
# the same symptoms.
# Which tables have a DATE-typed column that arrives as a DD/MM/YYYY
# text string and needs converting before it can be inserted into a
# real SQL DATE column. Discovered the hard way: the first real INSERT
# attempt against a live database failed with "Incorrect date value:
# '01/08/2024'" — this conversion was missing entirely until then,
# since every test up to that point used SQLite (which is lenient
# about date formats) rather than a real MySQL DATE column.
DATE_COLUMNS = {
    "mobo15_movements": ["posting_date"],
}
 
 
def parse_date_column(series: pd.Series) -> pd.Series:
    """Converts a DD/MM/YYYY text column into plain Python date objects
    (via .dt.date, NOT a pandas Timestamp) — the date-only form matters:
    a Timestamp stringifies as '2024-08-01 00:00:00' while a plain date
    stringifies as '2024-08-01'. If the two sides of the dedup
    comparison used different forms, the composite key would mismatch
    even for identical dates, silently recreating the exact 'everything
    looks new' bug this whole dedup rewrite was meant to fix. Any value
    that doesn't parse as a valid DD/MM/YYYY date — including the
    historical 'Not_found' placeholder documented in Week 1 profiling —
    becomes a true missing date (NaT / None) rather than crashing."""
    parsed = pd.to_datetime(series, format="%d/%m/%Y", errors="coerce")
    return parsed.dt.date
 
 
CLEANING_CONFIG = {
    "mobo15_movements": {
        "id_cols": {"item_no", "item_document", "mt"},
        "text_cols": {"item_description", "mt_text", "user_name"},
    },
    "mobo25_stock": {
        "id_cols": {"item_no"},
        "text_cols": {"item_description", "site_name"},
    },
}
 
 
def fix_mojibake(s: str):
    """Returns (repaired_text, status): 'clean' (no marker found),
    'fixed' (round-trip repair applied), or 'flagged' (marker found
    but not safely reversible — left as-is, needs a human look)."""
    if not s:
        return s, "clean"
    if any(marker in s for marker in MOJIBAKE_MARKERS):
        try:
            return s.encode("latin1").decode("utf-8"), "fixed"
        except (UnicodeDecodeError, UnicodeEncodeError):
            return s, "flagged"
    return s, "clean"
 
 
def clean_text_value(value, stats: dict):
    if pd.isna(value) or value is None:
        return value
    v = str(value)
    original_stripped = v.strip()
    v = NEWLINE_RE.sub(" ", v)                       # embedded newlines -> space
    v, mojibake_status = fix_mojibake(v)
    if mojibake_status == "fixed":
        stats["mojibake_fixed"] += 1
    elif mojibake_status == "flagged":
        stats["mojibake_flagged"] += 1
        if len(stats["flagged_examples"]) < 10:
            stats["flagged_examples"].append(v)
    v = unicodedata.normalize("NFC", v)
    v = WS_RE.sub(" ", v)                            # tabs/nbsp -> space
    v = re.sub(r" {2,}", " ", v)                      # collapse doubled spaces
    v = v.strip()
    if v != original_stripped:
        stats["whitespace_fixed"] += 1
    return v
 
 
def clean_id_value(value, stats: dict):
    """Strip a trailing '.0' float artifact from an otherwise-integer id
    (e.g. '100212326.0' -> '100212326'). This is a real, separate bug
    from the number-vs-text column-typing issue: it happens when a
    source export already wrote the '.0' as literal text, which no
    amount of forcing a column to Text dtype on read will fix — tested
    and confirmed before this was written."""
    if pd.isna(value) or value is None:
        return value
    v = str(value).strip()
    m = FLOAT_SUFFIX_RE.match(v)
    if m:
        stats["id_float_suffix_fixed"] += 1
        return m.group(1)
    return v
 
 
def run_cleaning_pass(df: pd.DataFrame, table_name: str, log) -> pd.DataFrame:
    """Applies the mojibake/whitespace/ID cleaning pass to whichever
    columns CLEANING_CONFIG says this table needs. No-op (returns df
    unchanged) for any table not listed there."""
    cfg = CLEANING_CONFIG.get(table_name)
    if cfg is None:
        return df
 
    stats = {
        "mojibake_fixed": 0, "mojibake_flagged": 0,
        "whitespace_fixed": 0, "id_float_suffix_fixed": 0,
        "flagged_examples": [],
    }
 
    for col in cfg["id_cols"]:
        if col in df.columns:
            df[col] = df[col].apply(lambda v: clean_id_value(v, stats))
 
    for col in cfg["text_cols"]:
        if col in df.columns:
            df[col] = df[col].apply(lambda v: clean_text_value(v, stats))
 
    log.info(f"    Cleaning pass ({table_name}): mojibake_fixed={stats['mojibake_fixed']}, "
             f"whitespace_fixed={stats['whitespace_fixed']}, "
             f"id_float_suffix_fixed={stats['id_float_suffix_fixed']}, "
             f"mojibake_flagged_for_review={stats['mojibake_flagged']}")
    if stats["mojibake_flagged"] > 0:
        log.warning(f"    {stats['mojibake_flagged']} cell(s) had mojibake that couldn't be "
                     f"safely auto-repaired — needs a human look. Examples: {stats['flagged_examples'][:3]}")
 
    return df
 
# =====================================================================
# CONFIGURATION — edit this section for your environment
# =====================================================================
 
DB_CONNECTION_STRING = "mysql+pymysql://loader:LoaderPass2026@192.168.1.153:3306/inventory_procurement"
 
# base filename (WITHOUT extension — the script auto-detects .csv or
# .xlsx, whichever is actually in the drop folder) -> (table name,
# load mode, dedup key)
# load mode: "replace" (snapshot) or "append" (transaction log)
# dedup key: only used for "append" mode — the column that uniquely
# identifies a transaction row, used to skip rows already loaded.
SOURCE_FILES = {
    "mobo25_stock":         ("mobo25_stock",        "replace", None),
    "mm_minmax":            ("mm_minmax",            "replace", None),
    "ms_item_setup":        ("ms_item_setup",        "replace", None),
    "mdb_item_master":      ("mdb_item_master",      "replace", None),
    "si_site":              ("si_site",              "replace", None),
    "cd_country":           ("cd_country",            "replace", None),
    "cx_currency_exchange": ("cx_currency_exchange", "replace", None),
    # dedup_key is a LIST of columns, not a single one — item_document
    # alone looked like a safe unique transaction ID, but real data
    # proved it isn't: the same item_document value recurs across many
    # completely different dates/items/quantities (confirmed on a real
    # file — one document number appeared 16 times across 16 different
    # dates). Using it alone as a dedup key silently matched 100% of a
    # 203,261-row file as "already loaded" when 196,410 of those rows
    # were dated well past what the database actually contained.
    # This composite (all 12 columns) was checked against the same real
    # file and reduced 203,261 rows to just 5 genuine exact duplicates
    # — the right level of specificity to trust.
    "mobo15_movements": ("mobo15_movements", "append", [
        "posting_date", "site", "mt_text", "mt", "item_document", "item_no",
        "item_description", "quantity", "base_uom", "user_name",
        "storage_location", "Purchase_order",
    ]),
    # If your MOBO15 file arrives named just "MOBO15.xlsx", either
    # rename it to "mobo15_movements.xlsx" before running, or add an
    # extra line here matching the pattern above.
}
 
# Columns that MUST be forced to text on load — these are the exact
# columns that broke Power BI search/filtering earlier in this project
# when auto-detected as numbers instead. Extend this list if a new
# ID-like column starts causing the same problem.
FORCE_TEXT_COLUMNS = [
    "item_no", "site", "mpn", "MPN", "purchase_order",
    "item_document", "tp_item_no", "tp_source_site", "tp_target_site",
]
 
LOG_FILE = "load_history.log"
 
# =====================================================================
# Implementation — shouldn't need editing below this line
# =====================================================================
 
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
console = logging.StreamHandler(sys.stdout)
console.setFormatter(logging.Formatter("%(message)s"))
logging.getLogger().addHandler(console)
log = logging.getLogger()
 
 
# base name used for the database table -> acceptable filename tokens
# (case-insensitive, matched as a whole token split on -, _, space —
# NOT a raw substring match, since short codes like "MS" or "SI" would
# false-positive against unrelated words like "items" or "missing").
# Includes both the actual short codes this project's real files use
# (SI, CD, CX, MM, MS, MDB, MOBO15, MOBO25) and longer descriptive
# fallbacks in case a future drop is named differently.
SEARCH_KEYWORDS = {
    "mobo25_stock":         ["mobo25"],
    "mm_minmax":            ["mm", "minmax"],
    "ms_item_setup":        ["ms", "itemsetup"],
    "mdb_item_master":      ["mdb", "itemmaster"],
    "si_site":              ["si", "site"],
    "cd_country":           ["cd", "country"],
    "cx_currency_exchange": ["cx", "currency"],
    "mobo15_movements":     ["mobo15"],
}
 
TOKEN_SPLIT_RE = re.compile(r"[-_ ]+")
 
 
def find_source_file(drop_folder: Path, base_name: str) -> Path | None:
    """Searches the drop folder for a .csv or .xlsx file whose name,
    split into tokens on '-'/'_'/space, contains one of this table's
    known keywords as a WHOLE token (case-insensitive) — e.g. matches
    'MOBO15.xlsx' or '1769441183365-MOBO15.csv' for table
    'mobo15_movements', and matches 'SI.csv' for 'si_site', but does
    NOT false-positive match 'MS' inside an unrelated word like
    'items.csv' the way a raw substring check would.
 
    If MORE THAN ONE file in the folder matches (e.g. an old
    'MOBO15_Clean.xlsx' left sitting next to a new 'MOBO15.xlsx' —
    both contain the token 'mobo15'), this raises an error rather than
    silently picking one. Which file gets picked in that situation
    isn't something you control or can predict, and loading the wrong
    one would look identical to a successful run until the numbers
    came out wrong — worth stopping and asking the user to remove the
    old file instead of guessing.
    """
    keywords = {kw.lower() for kw in SEARCH_KEYWORDS.get(base_name, [base_name])}
    candidates = list(drop_folder.glob("*.csv")) + list(drop_folder.glob("*.xlsx"))
    matches = []
    for path in candidates:
        tokens = {t.lower() for t in TOKEN_SPLIT_RE.split(path.stem) if t}
        if tokens & keywords:
            matches.append(path)
 
    if len(matches) > 1:
        names = ", ".join(p.name for p in matches)
        raise ValueError(
            f"AMBIGUOUS: {len(matches)} files in {drop_folder} all match table "
            f"'{base_name}': {names}. Remove or rename all but the one you actually "
            f"want loaded — each drop folder should contain exactly one file per table, "
            f"e.g. don't leave an old 'MOBO15_Clean.xlsx' sitting alongside a new "
            f"'MOBO15.xlsx' in the same folder."
        )
    return matches[0] if matches else None
 
 
def read_source_file(path: Path) -> pd.DataFrame:
    """Reads either a .csv or .xlsx file into a DataFrame, with every
    column forced to text at read time — this is what prevents the
    number-vs-text auto-detection bug from ever reaching the database."""
    if path.suffix.lower() == ".xlsx":
        df = pd.read_excel(path, dtype=str, keep_default_na=False, na_values=["", "NULL"])
    else:
        df = pd.read_csv(path, encoding="utf-8-sig", dtype=str, keep_default_na=False, na_values=["", "NULL"])
    return df
 
 
def source_row_count(path: Path) -> int:
    """Count data rows (excludes header). CSV-aware so quoted fields
    with embedded commas/newlines don't throw off a naive line count;
    for .xlsx, reads the sheet directly since there's no line-count
    shortcut for a binary spreadsheet format."""
    if path.suffix.lower() == ".xlsx":
        return len(pd.read_excel(path, dtype=str))
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        next(reader, None)
        return sum(1 for _ in reader)
 
 
def clean_id_cell(v):
    """Strips a trailing '.0' float-suffix artifact from a single cell,
    handling every value type a pandas column can actually contain —
    real string, float NaN, None, or pandas' newer pd.NA — explicitly,
    rather than assuming a prior .astype(str) call already normalized
    everything to a plain string. That assumption broke on a newer
    pandas version where a missing value survived as a genuine float
    instead of becoming the text 'nan', crashing the regex match with
    'expected string or bytes-like object, got float'. pd.isna() is
    the version-safe way to detect ANY of pandas' missing-value forms
    in one check, which is what this function relies on instead."""
    if pd.isna(v):
        return v
    v = str(v)
    m = FLOAT_SUFFIX_RE.match(v)
    return m.group(1) if m else v
 
 
def normalize_missing_values(df: pd.DataFrame) -> pd.DataFrame:
    """Defensive final pass: converts any cell that is EITHER already a
    recognized pandas missing value (NaN/None/pd.NA — checked via
    pd.isna(), which is safe across pandas versions) OR has become the
    literal TEXT 'nan'/'none'/'nat'/'<na>' (checked via string
    comparison, for the case where a missing value got stringified
    somewhere upstream) back to a true None. Runs as the very last
    step before every INSERT, catching the problem regardless of
    which upstream step — or which pandas version's quirks — let it
    through, rather than depending on one specific mechanism.
    """
    literal_missing = {"nan", "none", "nat", "<na>"}
    for col in df.columns:
        isna_mask = df[col].isna()
        text_mask = df[col].astype(str).str.strip().str.lower().isin(literal_missing)
        mask = isna_mask | text_mask
        if mask.any():
            df.loc[mask, col] = None
    return df
 
 
def load_snapshot_table(engine, file_path: Path, table_name: str):
    log.info(f"  Loading (replace) {table_name} from {file_path.name} ...")
    df = read_source_file(file_path)
 
    # Step 1: deep text/ID cleaning — only runs for tables in
    # CLEANING_CONFIG (currently mobo25_stock); no-op for everything else.
    df = run_cleaning_pass(df, table_name, log)
 
    # Step 1b: convert any DD/MM/YYYY date columns before they reach a
    # real SQL DATE column. No-op for tables without one configured.
    for col in DATE_COLUMNS.get(table_name, []):
        if col in df.columns:
            unparseable_before = df[col].isna().sum()
            df[col] = parse_date_column(df[col])
            unparseable_after = df[col].isna().sum()
            newly_unparseable = unparseable_after - unparseable_before
            if newly_unparseable > 0:
                log.warning(f"    {newly_unparseable} value(s) in '{col}' didn't match DD/MM/YYYY "
                             f"(e.g. the historical 'Not_found' placeholder) — set to NULL rather than crashing the load.")
 
    # Step 2: force ID-like columns to text, with a defensive .0-suffix
    # strip applied to EVERY table, not just the ones in CLEANING_CONFIG
    # — a cheap backstop in case a future table develops the same
    # export artifact that MOBO15/MOBO25 had.
    for col in df.columns:
        if col in FORCE_TEXT_COLUMNS:
            df[col] = df[col].apply(clean_id_cell)
 
    # Step 3: catch any cell that became the literal text 'nan'/'none'
    # somewhere above and convert it back to a true missing value —
    # see normalize_missing_values() docstring for why this exists.
    df = normalize_missing_values(df)
 
    with engine.begin() as conn:
        conn.execute(text(f"TRUNCATE TABLE {table_name}"))
        df.to_sql(table_name, conn, if_exists="append", index=False, chunksize=5000)
 
    return len(df)
 
 
def build_composite_key(df: pd.DataFrame, key_cols: list) -> pd.Series:
    """Builds one string column by concatenating every key column,
    separated by a character unlikely to appear in the data itself.
    Missing values are filled with an explicit placeholder rather than
    left as NaN — two rows that are BOTH missing the same field should
    still compare equal on that field, not silently fail to match."""
    parts = [df[c].fillna("§NULL§").astype(str) for c in key_cols]
    key = parts[0]
    for p in parts[1:]:
        key = key + "||" + p
    return key
 
 
def load_append_table(engine, file_path: Path, table_name: str, dedup_key):
    # dedup_key is a list of columns forming a composite key — see the
    # SOURCE_FILES comment for why a single column (item_document)
    # turned out to be unreliable on real data.
    key_cols = dedup_key if isinstance(dedup_key, list) else [dedup_key]
    log.info(f"  Loading (append, deduped on {key_cols}) {table_name} from {file_path.name} ...")
    df = read_source_file(file_path)
 
    # Same two-step cleaning as the snapshot loader — this is the path
    # mobo15_movements actually goes through.
    df = run_cleaning_pass(df, table_name, log)
 
    # Convert DD/MM/YYYY date columns BEFORE anything downstream uses
    # them — critically, before the composite dedup key gets built a
    # few lines down. If the new file's dates were left as raw text
    # while the EXISTING database rows come back from pd.read_sql as
    # proper date objects, the composite key would mismatch on every
    # single row purely from date formatting — silently recreating the
    # "everything looks new" bug this dedup rewrite was built to fix,
    # just from a different cause.
    for col in DATE_COLUMNS.get(table_name, []):
        if col in df.columns:
            unparseable_before = df[col].isna().sum()
            df[col] = parse_date_column(df[col])
            unparseable_after = df[col].isna().sum()
            newly_unparseable = unparseable_after - unparseable_before
            if newly_unparseable > 0:
                log.warning(f"    {newly_unparseable} value(s) in '{col}' didn't match DD/MM/YYYY "
                             f"(e.g. the historical 'Not_found' placeholder) — set to NULL rather than crashing the load.")
 
    for col in df.columns:
        if col in FORCE_TEXT_COLUMNS:
            df[col] = df[col].apply(clean_id_cell)
 
    # Same defensive pass as the snapshot loader — run BEFORE the dedup
    # comparison below, so a literal 'nan' string can't get treated as
    # a real, matchable key value.
    df = normalize_missing_values(df)
 
    missing_cols = [c for c in key_cols if c not in df.columns]
    if missing_cols:
        log.warning(f"  WARNING: dedup key column(s) {missing_cols} not found in {file_path.name} — loading all rows without dedup check.")
        new_rows = df
    else:
        df["_dedup_key"] = build_composite_key(df, key_cols)
 
        with engine.connect() as conn:
            existing = pd.read_sql(text(f"SELECT {', '.join(key_cols)} FROM {table_name}"), conn)
        existing["_dedup_key"] = build_composite_key(existing, key_cols)
        existing_keys = set(existing["_dedup_key"])
 
        new_rows = df[~df["_dedup_key"].isin(existing_keys)].drop(columns=["_dedup_key"])
        log.info(f"    {len(df)} rows in file, {len(df) - len(new_rows)} already present, {len(new_rows)} genuinely new")
 
    if len(new_rows) > 0:
        with engine.begin() as conn:
            new_rows.to_sql(table_name, conn, if_exists="append", index=False, chunksize=5000)
 
    return len(new_rows)
 
 
def run_parity_check(engine, drop_folder: Path):
    log.info("\n--- Row-count parity check ---")
    all_ok = True
    with engine.connect() as conn:
        for base_name, (table_name, mode, _) in SOURCE_FILES.items():
            try:
                file_path = find_source_file(drop_folder, base_name)
            except ValueError:
                continue  # already reported during the load loop above
            if file_path is None:
                continue
            loaded = conn.execute(text(f"SELECT COUNT(*) FROM {table_name}")).scalar()
            if mode == "replace":
                expected = source_row_count(file_path)
                status = "OK" if loaded == expected else "MISMATCH"
                if status == "MISMATCH":
                    all_ok = False
                log.info(f"  {table_name:<25} source={expected:>10,}  loaded={loaded:>10,}  {status}")
            else:
                log.info(f"  {table_name:<25} loaded={loaded:>10,}  (append table — no exact-match check, cumulative total)")
    return all_ok
 
 
def run_quality_checks(engine):
    log.info("\n--- Data quality flags (v_data_quality_flags) ---")
    with engine.connect() as conn:
        try:
            df = pd.read_sql(text("SELECT * FROM v_data_quality_flags"), conn)
        except Exception as e:
            log.warning(f"  Could not run v_data_quality_flags — has it been created? ({e})")
            return
    if len(df) == 0:
        log.info("  No issues found. Clean load.")
    else:
        log.warning(f"  {len(df)} issue(s) found — review before trusting this data in reports:")
        for _, row in df.iterrows():
            log.warning(f"    [{row['issue_type']}] site={row.get('site')} item_no={row.get('item_no')} detail={row.get('detail')} count={row.get('row_count')}")
 
    log.info("\n--- Currency coverage gap (v_currency_coverage_gap) ---")
    with engine.connect() as conn:
        try:
            gap = pd.read_sql(text("SELECT * FROM v_currency_coverage_gap"), conn)
        except Exception as e:
            log.warning(f"  Could not run v_currency_coverage_gap — has it been created? ({e})")
            return
    if len(gap) == 0:
        log.info("  Every site's currency has a GBP rate. No gap.")
    else:
        log.warning(f"  {len(gap)} site(s) with no GBP conversion rate:")
        for _, row in gap.iterrows():
            log.warning(f"    {row['site']} ({row['site_name']}, {row['country']}) — currency: {row['site_cur']}")
 
 
def main():
    if len(sys.argv) != 2:
        print("Usage: python load_new_data.py /path/to/dated_drop_folder/")
        sys.exit(1)
 
    drop_folder = Path(sys.argv[1])
    if not drop_folder.is_dir():
        print(f"Not a folder: {drop_folder}")
        sys.exit(1)
 
    log.info("=" * 70)
    log.info(f"LOAD RUN START — {datetime.now().isoformat()} — folder: {drop_folder}")
    log.info("=" * 70)
 
    engine = create_engine(DB_CONNECTION_STRING)
 
    ambiguous_found = False
    for base_name, (table_name, mode, dedup_key) in SOURCE_FILES.items():
        try:
            file_path = find_source_file(drop_folder, base_name)
        except ValueError as e:
            log.error(f"  {e}")
            ambiguous_found = True
            continue
        if file_path is None:
            log.warning(f"  SKIPPED — no file found for '{base_name}' in {drop_folder}")
            continue
        if mode == "replace":
            load_snapshot_table(engine, file_path, table_name)
        else:
            load_append_table(engine, file_path, table_name, dedup_key)
 
    if ambiguous_found:
        log.error("\nSTOPPING — one or more tables had ambiguous file matches (see above). "
                   "Fix the drop folder (remove/rename the extra file) and re-run. "
                   "Not proceeding to the parity/quality checks with incomplete data.")
        sys.exit(1)
 
    parity_ok = run_parity_check(engine, drop_folder)
    run_quality_checks(engine)
 
    log.info("\n" + "=" * 70)
    if parity_ok:
        log.info("LOAD RUN COMPLETE — row counts reconciled cleanly.")
    else:
        log.warning("LOAD RUN COMPLETE — WITH ROW-COUNT MISMATCHES. Review before trusting this data.")
    log.info("=" * 70 + "\n")
 
 
if __name__ == "__main__":
    main()
 