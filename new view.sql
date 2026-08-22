CREATE OR REPLACE VIEW v_site AS
SELECT
    s.id                	AS site_key,
    s.site,
    s.site_name,
    s.site_cur,
    c.country_id,
    c.country,
    cx_usd.rate             AS site_cur_per_usd,
    cx_gbp.rate             AS site_cur_per_gbp
FROM si_site s
LEFT JOIN cd_country c  ON s.country_id = c.country_id
LEFT JOIN cx_currency_exchange cx_gbp
       ON cx_gbp.fm_cur = s.site_cur AND cx_gbp.to_cur = 'GBP'
LEFT JOIN cx_currency_exchange cx_usd
       ON cx_usd.fm_cur = s.site_cur AND cx_usd.to_cur = 'USD';


CREATE OR REPLACE VIEW v_site_currency_gap AS
SELECT site, site_name, site_cur
FROM v_site
WHERE site_cur_per_gbp IS NULL AND site_cur IS NOT NULL;


CREATE OR REPLACE VIEW v_item AS
SELECT
    item_no,
    NULLIF(TRIM(MPN), '')              AS mpn,
    company_id,
    NULLIF(TRIM(item_description), '') AS item_description
FROM mdb_item_master;


CREATE OR REPLACE VIEW v_stock_current AS
SELECT
    m.id AS stock_row_id,
    m.site,
    COALESCE(s.site_name, m.site_name)     AS site_name,
    s.country,
    s.site_cur,
    m.item_no,
    COALESCE(i.item_description, m.item_description) AS item_description,
    m.storage_location,
    m.base_uom,
    m.unrestricted,
    m.in_quality_insp,
    m.restricted_use_stock,
    m.blocked,
    m.value_unrestricted,
    m.currency,
    CASE WHEN s.site_cur_per_usd IS NOT NULL
         THEN ROUND(m.value_unrestricted / s.site_cur_per_usd, 2)
         ELSE NULL END                     AS value_unrestricted_usd,
	CASE WHEN s.site_cur_per_gbp IS NOT NULL
         THEN ROUND(m.value_unrestricted / s.site_cur_per_gbp, 2)
         ELSE NULL END                     AS value_unrestricted_gbp
FROM mobo25_stock m
LEFT JOIN v_site s ON m.site = s.site
LEFT JOIN v_item i ON m.item_no = i.item_no;


CREATE OR REPLACE VIEW v_movements AS
SELECT
    mo.id AS movement_row_id,
    mo.posting_date,
    mo.site,
    mo.mt,
    CASE mo.mt WHEN '471' THEN 'Goods Issued' WHEN '472' THEN 'Reversed' END AS mt_label,
    mo.item_no,
    COALESCE(i.item_description, mo.item_description) AS item_description,
    mo.quantity,
    mo.base_uom,
    mo.storage_location,
    mo.purchase_order
FROM mobo15_movements mo
LEFT JOIN v_item i ON mo.item_no = i.item_no
WHERE mo.mt IN ('471', '472');



CREATE OR REPLACE VIEW v_opportunity_seed AS
SELECT
    mm.item_no,
    mm.site,
    s.site_name,
    s.country,
    mm.movement_status,
    mm.average_issue_6,
    mm.average_issue_12,
    mm.average_quantity_6,
    mm.average_quantity_12,
    mm.maximum_quantity,
    mm.calculated_maximum,
    NULLIF(ms.minimum_level, 0) AS minimum_level,
    ms.reorder_point,
    NULLIF(ms.maximum_level, 0) AS maximum_level,
    stk.total_unrestricted,
    stk.total_value_usd,
    stk.total_value_gbp,
    CASE
        WHEN NULLIF(ms.maximum_level, 0) IS NOT NULL AND stk.total_unrestricted > NULLIF(ms.maximum_level, 0)
            THEN 'Overstock'
        WHEN NULLIF(ms.minimum_level, 0) IS NOT NULL AND stk.total_unrestricted < NULLIF(ms.minimum_level, 0)
            THEN 'Understock'
        ELSE 'Within range'
    END AS stock_position
FROM mm_minmax mm
LEFT JOIN v_site s ON mm.site = s.site
LEFT JOIN ms_item_setup ms ON ms.site = mm.site AND ms.item_no = mm.item_no
LEFT JOIN (
    SELECT site, item_no,
           SUM(unrestricted)          AS total_unrestricted,
           SUM(value_unrestricted_usd) AS total_value_usd,
           SUM(value_unrestricted_gbp) AS total_value_gbp
    FROM v_stock_current
    GROUP BY site, item_no
) stk ON stk.site = mm.site AND stk.item_no = mm.item_no;



CREATE OR REPLACE VIEW v_transfer_candidates AS
SELECT
    src.item_no,
    src.site                AS source_site,
    src.site_name            AS source_site_name,
    src.movement_status      AS source_movement_status,
    src.total_unrestricted   AS source_stock_qty,
    src.total_value_usd      AS source_stock_value_usd,
    tgt.site                AS target_site,
    tgt.site_name             AS target_site_name,
    tgt.movement_status       AS target_movement_status,
    tgt.stock_position        AS target_stock_position,
    tgt.total_unrestricted    AS target_stock_qty,
    tgt.minimum_level         AS target_minimum_level
FROM v_opportunity_seed src
JOIN v_opportunity_seed tgt
    ON src.item_no = tgt.item_no
    AND src.site != tgt.site
WHERE src.movement_status IN ('No Mover', 'Slow')
    AND src.total_unrestricted > 0
    AND (tgt.movement_status = 'Fast' OR tgt.stock_position = 'Understock');















CREATE OR REPLACE VIEW v_item_site_unit_value AS
SELECT
    m.site,
    m.item_no,
    SUM(m.unrestricted)                                    AS on_hand_qty,
    SUM(m.value_unrestricted)                              AS on_hand_value_local,
    s.site_cur_per_gbp,
    CASE WHEN s.site_cur_per_gbp IS NOT NULL
         THEN SUM(m.value_unrestricted) / s.site_cur_per_gbp
         ELSE NULL END                                     AS on_hand_value_gbp,
    CASE WHEN s.site_cur_per_gbp IS NOT NULL AND SUM(m.unrestricted) > 0
         THEN (SUM(m.value_unrestricted) / s.site_cur_per_gbp) / SUM(m.unrestricted)
         ELSE NULL END                                     AS unit_value_gbp
FROM mobo25_stock m
LEFT JOIN v_site s ON m.site = s.site
GROUP BY m.site, m.item_no, s.site_cur_per_gbp;



CREATE OR REPLACE VIEW v_kpi_year_calendar AS
WITH RECURSIVE bounds AS (
    SELECT YEAR(MIN(posting_date)) AS min_yr, YEAR(MAX(posting_date)) AS max_yr
    FROM mobo15_movements WHERE posting_date IS NOT NULL
),
year_seq AS (
    SELECT min_yr AS yr FROM bounds
    UNION ALL
    SELECT yr + 1 FROM year_seq, bounds WHERE yr + 1 <= max_yr
),
year_data AS (
    SELECT
        YEAR(posting_date) AS yr,
        MIN(posting_date)  AS first_date_with_data,
        MAX(posting_date)  AS last_date_with_data
    FROM mobo15_movements
    WHERE posting_date IS NOT NULL
    GROUP BY YEAR(posting_date)
)
SELECT
    ys.yr,
    DATE(CONCAT(ys.yr, '-01-01'))                         AS yr_start,
    DATE(CONCAT(ys.yr, '-12-31'))                         AS yr_end,
    yd.first_date_with_data,
    yd.last_date_with_data,
    DATEDIFF(yd.last_date_with_data, yd.first_date_with_data) + 1 AS days_present,
    (yd.first_date_with_data > DATE(CONCAT(ys.yr, '-01-01'))
     OR yd.last_date_with_data < DATE(CONCAT(ys.yr, '-12-31')))   AS is_partial_year
FROM year_seq ys
JOIN year_data yd ON yd.yr = ys.yr;




CREATE OR REPLACE VIEW v_kpi_issued_by_year AS
SELECT
    YEAR(mo.posting_date)                AS yr,
    SUM(-mo.quantity)                    AS total_issued_qty,
    SUM(-mo.quantity * v.unit_value_gbp) AS total_cogs_gbp
FROM mobo15_movements mo
LEFT JOIN v_item_site_unit_value v ON mo.item_no = v.item_no AND mo.site = v.site
WHERE mo.mt IN ('471','472') AND mo.posting_date IS NOT NULL
GROUP BY YEAR(mo.posting_date);




CREATE OR REPLACE VIEW v_kpi_turnover_trailing_12mo AS
WITH bounds AS (
    SELECT MAX(posting_date)                          AS window_end,
           DATE_SUB(MAX(posting_date), INTERVAL 365 DAY) AS window_start
    FROM mobo15_movements WHERE posting_date IS NOT NULL
),
issued AS (
    SELECT
        mo.item_no, mo.site,
        SUM(-mo.quantity)                    AS net_issued_qty,
        SUM(-mo.quantity * v.unit_value_gbp) AS cogs_proxy_gbp
    FROM mobo15_movements mo
    CROSS JOIN bounds b
    LEFT JOIN v_item_site_unit_value v ON mo.item_no = v.item_no AND mo.site = v.site
    WHERE mo.mt IN ('471','472')
      AND mo.posting_date > b.window_start
      AND mo.posting_date <= b.window_end
    GROUP BY mo.item_no, mo.site
)
SELECT
    (SELECT window_start FROM bounds) AS window_start,
    (SELECT window_end FROM bounds) AS window_end,
    COALESCE(SUM(i.net_issued_qty), 0) AS total_issued_qty,
    COALESCE(SUM(i.cogs_proxy_gbp), 0) AS total_cogs_gbp,
    (SELECT SUM(on_hand_qty) FROM v_item_site_unit_value) AS current_on_hand_qty,
    (SELECT SUM(on_hand_value_gbp) FROM v_item_site_unit_value) AS current_inventory_value_gbp,
    ROUND(COALESCE(SUM(i.net_issued_qty),0) /
          NULLIF((SELECT SUM(on_hand_qty) FROM v_item_site_unit_value),0), 3) AS turnover_qty_ratio,
    ROUND(COALESCE(SUM(i.cogs_proxy_gbp),0) /
          NULLIF((SELECT SUM(on_hand_value_gbp) FROM v_item_site_unit_value),0), 3) AS turnover_value_ratio,
    ROUND((SELECT SUM(on_hand_value_gbp) FROM v_item_site_unit_value) /
          NULLIF(SUM(i.cogs_proxy_gbp),0) * 365, 1)                                 AS dio_days
FROM issued i;
 




CREATE OR REPLACE VIEW v_kpi_stockout_raw AS
WITH tracked AS (
    SELECT DISTINCT site, item_no FROM ms_item_setup
    WHERE deletion_indicator IS NULL OR deletion_indicator != 'X'
),
stock AS (
    SELECT site, item_no, SUM(unrestricted) AS on_hand FROM mobo25_stock GROUP BY site, item_no
)
SELECT
    COUNT(*)                                                          AS tracked_combos,
    SUM(CASE WHEN COALESCE(s.on_hand,0) <= 0 THEN 1 ELSE 0 END)       AS stockout_combos,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(s.on_hand,0) <= 0 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                              AS stockout_rate_pct
FROM tracked t
LEFT JOIN stock s ON t.site = s.site AND t.item_no = s.item_no;
 
 
 
 
 
CREATE OR REPLACE VIEW v_kpi_stockout_demand_weighted_by_year AS
WITH stock AS (
    SELECT site, item_no, SUM(unrestricted) AS on_hand FROM mobo25_stock GROUP BY site, item_no
),
demand AS (
    SELECT DISTINCT YEAR(posting_date) AS yr, site, item_no
    FROM mobo15_movements
    WHERE mt = '471' AND posting_date IS NOT NULL
)
SELECT
    d.yr,
    COUNT(*)                                                          AS demand_combos,
    SUM(CASE WHEN COALESCE(s.on_hand,0) <= 0 THEN 1 ELSE 0 END)       AS stockout_combos,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(s.on_hand,0) <= 0 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                              AS stockout_rate_pct
FROM demand d
LEFT JOIN stock s ON d.site = s.site AND d.item_no = s.item_no
GROUP BY d.yr;


CREATE OR REPLACE VIEW v_kpi_reorder_frequency_by_year AS
SELECT
    YEAR(posting_date)             AS yr,
    item_no, site,
    COUNT(DISTINCT purchase_order) AS distinct_pos,
    COUNT(*)                       AS receipt_lines
FROM mobo15_movements
WHERE mt = '311' AND posting_date IS NOT NULL AND purchase_order IS NOT NULL
GROUP BY YEAR(posting_date), item_no, site;




USE inventory_procurement;

CREATE OR REPLACE VIEW v_kpi_excess_inventory AS
SELECT
    SUM(CASE WHEN stock_position = 'Overstock' THEN total_value_gbp ELSE 0 END) AS overstock_value_gbp,
    SUM(total_value_gbp) AS total_value_gbp,
    ROUND(100.0 * SUM(CASE WHEN stock_position = 'Overstock' THEN total_value_gbp ELSE 0 END)
          / NULLIF(SUM(total_value_gbp),0), 2) AS excess_inventory_rate_pct
FROM v_opportunity_seed
WHERE total_value_gbp IS NOT NULL;
