-- ============================================================================
-- Inventory / Procurement Analytics — Schema
-- Target: MySQL 8.0+ (InnoDB, utf8mb4)
-- Source datasets: CD, CX, SI, MM, MS, MDB, MOBO15, MOBO25
-- ============================================================================

CREATE DATABASE IF NOT EXISTS inventory_procurement
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE inventory_procurement;

SET FOREIGN_KEY_CHECKS = 0;

-- ----------------------------------------------------------------------------
-- 1. CD — Country Data (reference)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS cd_country;
CREATE TABLE cd_country (
    country_id      INT UNSIGNED    NOT NULL,
    country         VARCHAR(100)    NOT NULL,
    PRIMARY KEY (country_id),
    UNIQUE KEY uq_cd_country_name (country)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 2. CX — Currency Exchange Rates (reference)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS cx_currency_exchange;
CREATE TABLE cx_currency_exchange (
    sid             INT UNSIGNED    NOT NULL,
    customer_group  VARCHAR(50)     NULL,
    fm_cur          CHAR(3)         NOT NULL,
    to_cur          CHAR(3)         NOT NULL,
    rate            DECIMAL(14,6)   NOT NULL,
    PRIMARY KEY (sid),
    UNIQUE KEY uq_cx_pair (fm_cur, to_cur)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 3. SI — Site Information (reference; site is the natural business key
--    used by every fact table, so it carries its own unique index)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS si_site;
CREATE TABLE si_site (
    id              INT UNSIGNED    NOT NULL,
    site            VARCHAR(20)     NOT NULL,
    site_name       VARCHAR(100)    NULL,
    site_cur        CHAR(3)         NULL,
    country_id      INT UNSIGNED    NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_si_site (site),
    KEY idx_si_country (country_id),
    CONSTRAINT fk_si_country FOREIGN KEY (country_id)
        REFERENCES cd_country (country_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 4. MDB — Master Database / Item master
--    item_no is unique in source (180,143 rows / 180,143 distinct item_no)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS mdb_item_master;
CREATE TABLE mdb_item_master (
    item_no             VARCHAR(20)   NOT NULL,
    mpn                 VARCHAR(50)   NULL,
    company_id          VARCHAR(20)   NOT NULL,
    item_description    VARCHAR(255)  NULL,
    PRIMARY KEY (item_no),
    KEY idx_mdb_mpn (mpn),
    KEY idx_mdb_company (company_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 5. MM — MinMax planning parameters
--    natural key = (item_no, site); source has no id collisions on either
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS mm_minmax;
CREATE TABLE mm_minmax (
    id                      INT UNSIGNED    NOT NULL,
    item_no                 VARCHAR(20)     NOT NULL,
    site                    VARCHAR(20)     NOT NULL,
    average_issue_6         DECIMAL(18,3)   NULL,
    average_issue_12        DECIMAL(18,3)   NULL,
    average_quantity_6      DECIMAL(18,3)   NULL,
    average_quantity_12     DECIMAL(18,3)   NULL,   -- source col: aveverage_quantity_12
    maximum_quantity        DECIMAL(18,3)   NULL,
    calculated_maximum      DECIMAL(18,3)   NULL,
    movement_status         VARCHAR(20)     NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_mm_item_site (item_no, site),
    KEY idx_mm_site (site),
    CONSTRAINT fk_mm_site FOREIGN KEY (site) REFERENCES si_site (site)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 6. MS — Item Setup (min/max/reorder policy per site+item)
--    source has no surrogate id column -> generate one on load
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ms_item_setup;
CREATE TABLE ms_item_setup (
    id                  INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    site                VARCHAR(20)     NOT NULL,
    item_no             VARCHAR(20)     NOT NULL,
    minimum_level       DECIMAL(18,3)   NULL,
    reorder_point       DECIMAL(18,3)   NULL,
    fixed_lot           VARCHAR(20)     NULL,
    maximum_level       DECIMAL(18,3)   NULL,
    deletion_indicator  VARCHAR(10)     NULL,
    item_status         VARCHAR(20)     NULL,
    mrp_type            VARCHAR(10)     NULL,
    lot_size            VARCHAR(10)     NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_ms_site_item (site, item_no),
    KEY idx_ms_site (site),
    CONSTRAINT fk_ms_site FOREIGN KEY (site) REFERENCES si_site (site)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 7. MOBO15 — Movement Orders / Inventory Transactions (transaction log)
--    No natural PK (item_document repeats across line items) -> surrogate id
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS mobo15_movements;
CREATE TABLE mobo15_movements (
    id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    posting_date        DATE            NULL,      -- source col: posring_date
    site                VARCHAR(20)     NULL,
    mt_text             VARCHAR(50)     NULL,
    mt                  SMALLINT UNSIGNED NULL,     -- movement type, e.g. 471=issue, 472=reversal
    item_document       VARCHAR(20)     NULL,
    item_no             VARCHAR(20)     NULL,
    item_description    VARCHAR(255)    NULL,
    quantity            DECIMAL(18,3)   NULL,
    base_uom            VARCHAR(10)     NULL,
    user_name           VARCHAR(50)     NULL,
    storage_location    VARCHAR(20)     NULL,
    purchase_order      VARCHAR(20)     NULL,
    PRIMARY KEY (id),
    KEY idx_mobo15_site_item (site, item_no),
    KEY idx_mobo15_date (posting_date),
    KEY idx_mobo15_mt (mt),
    KEY idx_mobo15_doc (item_document)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- 8. MOBO25 — Current Stock Levels (snapshot)
--    No natural PK (285 dup on site+item_no+storage_location) -> surrogate id
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS mobo25_stock;
CREATE TABLE mobo25_stock (
    id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    site                    VARCHAR(20)     NULL,
    site_name               VARCHAR(100)    NULL,
    item_no                 VARCHAR(20)     NULL,
    item_description        VARCHAR(255)    NULL,
    storage_location        VARCHAR(20)     NULL,
    base_uom                VARCHAR(10)     NULL,   -- source col: Base Unit of Measure
    unrestricted            DECIMAL(18,3)   NULL,
    in_quality_insp         DECIMAL(18,3)   NULL,
    restricted_use_stock    DECIMAL(18,3)   NULL,
    blocked                 DECIMAL(18,3)   NULL,
    value_unrestricted      DECIMAL(18,2)   NULL,
    currency                CHAR(3)         NULL,
    PRIMARY KEY (id),
    KEY idx_mobo25_site_item (site, item_no),
    KEY idx_mobo25_currency (currency)
) ENGINE=InnoDB;

SET FOREIGN_KEY_CHECKS = 1;

-- ----------------------------------------------------------------------------
-- Notes on referential integrity (see row_count_parity_report.md for detail):
--  - mobo15_movements.site / mobo25_stock.site and .item_no are NOT declared
--    as FKs. 24 rows in MOBO15 carry malformed site codes (e.g. 'GNULPL',
--    'G-20P0') that don't exist in si_site, and both MOBO tables reference
--    item_no values not present in mdb_item_master (389 in MOBO15 after
--    cleaning, ~300k in MOBO25 — MDB is not a complete item master for all
--    sites/items in current stock). Enforcing a hard FK here would reject
--    those rows outright; they are loaded and flagged in the exceptions
--    report instead, which is the safer default for a first load.
-- ============================================================================
