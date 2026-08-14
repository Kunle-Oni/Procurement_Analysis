"""
verify_row_parity.py
=====================
Confirms that clean_mobo.py didn't lose (or gain) any rows while
cleaning MOBO15/MOBO25 — run this after clean_mobo.py, on your own
files, to check it yourself rather than take it on faith.

Checks THREE things, each printed clearly:
  1. True row count of the RAW file (CSV-aware — correctly handles
     embedded newlines inside quoted fields, unlike a naive line count
     or "wc -l").
  2. Row count of the CLEANED output file.
  3. Whether they match. If they don't, something is genuinely wrong
     and worth investigating before trusting the cleaned file.

Also reports the "naive vs true" comparison for your own information —
this is the same reconciliation used to confirm MOBO25 correctly
preserved 158 rows containing embedded newlines during the original
validation of this script.

USAGE
-----
    python3 verify_row_parity.py /path/to/raw_MOBO15.csv /path/to/clean/MOBO15_clean.csv
    python3 verify_row_parity.py /path/to/raw_MOBO25.csv /path/to/clean/MOBO25_clean.csv
"""
import csv
import sys
from pathlib import Path


def naive_line_count(path: Path) -> int:
    """A quick, NOT reliable count — treats every line break as a row
    boundary, which is wrong for any row with an embedded newline in a
    quoted field. Shown for comparison only, never trust this number
    on its own."""
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return sum(1 for _ in f) - 1  # minus header


def true_row_count(path: Path) -> int:
    """The correct count — respects CSV quoting rules, so an embedded
    newline inside a quoted field is correctly treated as part of that
    field's content, not as a new row."""
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)  # skip header
        return sum(1 for _ in reader)


def count_embedded_newline_rows(path: Path) -> int:
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)
        count = 0
        for row in reader:
            if any(("\n" in cell or "\r" in cell) for cell in row):
                count += 1
        return count


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 verify_row_parity.py <raw_file.csv> <cleaned_file.csv>")
        sys.exit(1)

    raw_path = Path(sys.argv[1])
    clean_path = Path(sys.argv[2])

    for p in (raw_path, clean_path):
        if not p.exists():
            print(f"File not found: {p}")
            sys.exit(1)

    print(f"Raw file:     {raw_path.name}")
    print(f"Cleaned file: {clean_path.name}")
    print()

    naive = naive_line_count(raw_path)
    true_raw = true_row_count(raw_path)
    true_clean = true_row_count(clean_path)
    embedded = count_embedded_newline_rows(raw_path)

    print(f"Naive line count of raw file (informational only, don't trust alone): {naive:,}")
    print(f"True row count of raw file (CSV-aware):                              {true_raw:,}")
    print(f"Rows in raw file with an embedded newline in a field:                {embedded:,}")
    print(f"Row count of cleaned output file:                                    {true_clean:,}")
    print()

    if naive != true_raw:
        gap = naive - true_raw
        print(f"Note: naive count and true count differ by {gap} — expected when embedded "
              f"newlines are present (each one adds a spurious extra 'line' to a naive count). "
              f"This is normal, not an error, as long as the checks below pass.")
        print()

    if true_raw == true_clean:
        print(f"PASS — row parity confirmed. {true_raw:,} rows in, {true_clean:,} rows out. No rows lost.")
    else:
        diff = true_raw - true_clean
        print(f"FAIL — row count MISMATCH. Raw has {true_raw:,} rows, cleaned file has {true_clean:,} "
              f"({'lost' if diff > 0 else 'gained'} {abs(diff):,} rows). "
              f"Do not trust this cleaned file until this is investigated.")
        sys.exit(1)


if __name__ == "__main__":
    main()
