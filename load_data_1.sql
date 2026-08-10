-- ============================================================================
-- load_data.sql
-- Explicit LOAD DATA LOCAL INFILE statements for all 8 tables.
-- Run this INSTEAD of the Table Data Import Wizard -- the wizard auto-builds
-- its own column list from the CSV header and can mis-map headers that
-- contain punctuation (e.g. "In Quality Insp.", "Restricted-Use Stock"),
-- which is what threw "Column 'storage_location' specified twice" (error
-- 1110). Writing the LOAD DATA statement ourselves removes that ambiguity
-- completely -- every source column is mapped to a target column by name,
-- explicitly, once.
--
-- FIXED (was previously buggy): all 8 source CSVs use Windows-style line
-- endings (\r\n), but this script originally said
-- LINES TERMINATED BY '\n' -- Unix-style only. MySQL still parsed rows
-- correctly, but left a trailing \r stuck to the LAST column of every row
-- in every table (cd_country.country, mdb_item_master.item_description,
-- mm_minmax.movement_status, ms_item_setup.lot_size,
-- mobo15_movements.purchase_order, mobo25_stock.currency). That made every
-- exact-string match against those columns silently fail, e.g.
-- 'Fast\r' <> 'Fast'. Now fixed to LINES TERMINATED BY '\r\n'.
--
-- Because your database was already loaded with the buggy version, this
-- script now TRUNCATEs each table before reloading it, so re-running it is
-- safe and replaces the corrupted data cleanly rather than duplicating rows.
--
-- BEFORE RUNNING:
--   1. Run schema.sql first to create the 8 empty tables.
--   2. Edit the file paths below (@'...') to wherever the CSVs live on
--      your machine. On Windows use double backslashes or forward slashes.
--   3. Client-side LOCAL INFILE must be enabled. In MySQL Workbench:
--      Edit > Preferences > SQL Editor > check "Enable Load Data Local
--      Infile", then reconnect. On the server, run once:
--         SET GLOBAL local_infile = 1;
--   4. Use MOBO15_clean.csv / MOBO25_clean.csv (the cleaned files), not
--      the raw uploads -- they've already had the whitespace/encoding/
--      float-suffix issues fixed.
-- ============================================================================

USE inventory_procurement;
SET GLOBAL local_infile = 1;

-- Clear out any previously (buggy) loaded data before reloading cleanly.
-- FK checks disabled temporarily so truncate order doesn't matter.
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE cd_country;
TRUNCATE TABLE cx_currency_exchange;
TRUNCATE TABLE si_site;
TRUNCATE TABLE mdb_item_master;
TRUNCATE TABLE mm_minmax;
TRUNCATE TABLE ms_item_setup;
TRUNCATE TABLE mobo15_movements;
TRUNCATE TABLE mobo25_stock;
SET FOREIGN_KEY_CHECKS = 1;

-- ----------------------------------------------------------------------------
-- 1. CD — Country Data
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441253767-CD.csv'
INTO TABLE cd_country
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(country_id, country);

-- ----------------------------------------------------------------------------
-- 2. CX — Currency Exchange Rates
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441253942-CX.csv'
INTO TABLE cx_currency_exchange
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(sid, @customer_group, fm_cur, to_cur, rate)
SET customer_group = NULLIF(@customer_group, 'NULL');

-- ----------------------------------------------------------------------------
-- 3. SI — Site Information
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441194878-SI.csv'
INTO TABLE si_site
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(id, site, site_name, site_cur, @country_id)
SET country_id = NULLIF(@country_id, 'NULL');

-- ----------------------------------------------------------------------------
-- 4. MDB — Master Database / Item master
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441233720-MDB.csv'
INTO TABLE mdb_item_master
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(@mpn, item_no, company_id, @item_description)
SET mpn = NULLIF(@mpn, ''),
    item_description = NULLIF(@item_description, '');
-- Note: source column order is MPN, item_no, company_id, item_description --
-- table column order differs (item_no first, as PK), so this mapping is
-- deliberately not 1:1 positional.

-- ----------------------------------------------------------------------------
-- 5. MM — MinMax
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441195082-MM.csv'
INTO TABLE mm_minmax
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(id, item_no, site, average_issue_6, average_issue_12, average_quantity_6,
 average_quantity_12, maximum_quantity, calculated_maximum, @movement_status)
SET movement_status = NULLIF(@movement_status, '');
-- source header is "aveverage_quantity_12" (typo in source) -> maps to
-- table column average_quantity_12 by position, which is correct here.

-- ----------------------------------------------------------------------------
-- 6. MS — Item Setup (no id column in source -> let AUTO_INCREMENT fill it)
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/1769441231065-MS.csv'
INTO TABLE ms_item_setup
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(site, item_no, @minimum_level, reorder_point, @fixed_lot, maximum_level,
 @deletion_indicator, @item_status, mrp_type, lot_size)
SET minimum_level = NULLIF(@minimum_level, 'NULL'),
    fixed_lot = NULLIF(@fixed_lot, 'NULL'),
    deletion_indicator = NULLIF(@deletion_indicator, 'NULL'),
    item_status = NULLIF(@item_status, 'NULL');

-- ----------------------------------------------------------------------------
-- 7. MOBO15 — Movement Orders / Inventory Transactions
--    Use MOBO15_clean.csv (from clean_mobo.py), NOT the raw upload.
--    Table column order differs from the CSV, so map explicitly.
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/MOBO15_clean.csv'
INTO TABLE mobo15_movements
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(@posring_date, @site, @mt_text, @mt, @item_document, @item_no,
 @item_description, quantity, base_uom, user_name, storage_location,
 @purchase_order)
SET posting_date   = STR_TO_DATE(@posring_date, '%d/%m/%Y'),
    site            = NULLIF(@site, ''),
    mt_text         = NULLIF(@mt_text, ''),
    mt              = NULLIF(@mt, ''),
    item_document   = NULLIF(@item_document, ''),
    item_no         = NULLIF(@item_no, ''),
    item_description = NULLIF(@item_description, ''),
    purchase_order  = NULLIF(@purchase_order, '');

-- ----------------------------------------------------------------------------
-- 8. MOBO25 — Current Stock Levels
--    Use MOBO25_clean.csv (from clean_mobo.py), NOT the raw upload.
--    This is the file/table combination that threw the original
--    "Column 'storage_location' specified twice" error in the wizard --
--    the explicit column list below has storage_location listed exactly
--    once, mapped from the CSV's "Storage Location" column.
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '/Users/kunleoni/Downloads/procurement_analysis/MOBO25_clean.csv'
INTO TABLE mobo25_stock
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(site, site_name, item_no, @item_description, storage_location, base_uom,
 unrestricted, in_quality_insp, restricted_use_stock, blocked,
 value_unrestricted, currency)
SET item_description = NULLIF(@item_description, '');

-- ----------------------------------------------------------------------------
-- Row-count parity check (run after all 8 loads complete)
-- ----------------------------------------------------------------------------
SELECT 'cd_country' AS tbl, COUNT(*) AS row_count FROM cd_country
UNION ALL SELECT 'cx_currency_exchange', COUNT(*) FROM cx_currency_exchange
UNION ALL SELECT 'si_site', COUNT(*) FROM si_site
UNION ALL SELECT 'mdb_item_master', COUNT(*) FROM mdb_item_master
UNION ALL SELECT 'mm_minmax', COUNT(*) FROM mm_minmax
UNION ALL SELECT 'ms_item_setup', COUNT(*) FROM ms_item_setup
UNION ALL SELECT 'mobo15_movements', COUNT(*) FROM mobo15_movements
UNION ALL SELECT 'mobo25_stock', COUNT(*) FROM mobo25_stock;
-- Expected: 20, 22, 72, 180143, 36671, 119135, 203265, 556928
-- (matches out/row_count_parity_report.md from the SQLite proof-of-concept load)
