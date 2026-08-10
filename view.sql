CREATE OR REPLACE VIEW v_item_site_explorer AS
WITH stock AS (
    /*Current stock, collapsed to one row per site+item (MOBO25 has multiple storage-location rows per site+item; summed together
    since this view doesn't need storage-location detail). */
    SELECT
        m.site,
        m.item_no,
        SUM(m.unrestricted)       AS on_hand_qty,
        SUM(m.value_unrestricted) AS on_hand_value_local
    FROM mobo25_stock m
    WHERE m.site IS NOT NULL AND m.item_no IS NOT NULL
    GROUP BY m.site, m.item_no
),
site_ctx AS (
    -- Site + country + GBP exchange rate, one row per site.
    SELECT
        s.site,
        s.site_name,
        s.site_cur,
        cd.country,
        fx.rate AS site_cur_per_gbp
    FROM si_site s
    LEFT JOIN cd_country cd ON s.country_id = cd.country_id
    LEFT JOIN cx_currency_exchange fx ON fx.fm_cur = s.site_cur AND fx.to_cur = 'GBP'
),
movement_summary AS (
    /* mobo15-derived recency/frequency, per item+site. LEFT JOINed in below, not part of `stock`'s own grain: most item+site
    combinations in mobo25 (479,196 items) have NO mobo15 history at all (mobo15 only covers 48,229 distinct items), so these columns are NULL for the majority of rows.
    no transaction was ever logged for that item at that site in this extract, not that the item doesn't exist.*/
    SELECT
        site, item_no,
        MAX(posting_date) AS last_movement_date,
        SUM(CASE WHEN mt IN ('471','472')
                 AND posting_date > (SELECT DATE_SUB(MAX(posting_date), INTERVAL 365 DAY) FROM mobo15_movements WHERE posting_date IS NOT NULL)
                 THEN 1 ELSE 0 END) AS movement_count_trailing_12mo
    FROM mobo15_movements
    WHERE posting_date IS NOT NULL
    GROUP BY site, item_no
),
last_movement_type AS (
    /* The mt of each item+site's single most recent transaction. Only the LATEST movement's type is kept (not a breakdown across all
    historical mt codes) precisely because of the grain problem described above — this is one deliberately chosen summary fact,
    not an attempt to flatten the full transaction history.*/
    SELECT site, item_no, mt AS last_movement_type
    FROM (
        SELECT site, item_no, mt,
               ROW_NUMBER() OVER (PARTITION BY site, item_no ORDER BY posting_date DESC) AS rn
        FROM mobo15_movements
        WHERE posting_date IS NOT NULL
    ) ranked
    WHERE rn = 1
),
enriched AS (
    /* The core item+site row: quantity, value, movement status, MRP position — everything except the cross-site transfer context,
    added in the final SELECT below.*/
    SELECT
        st.site,
        sc.site_name,
        sc.country,
        sc.site_cur,
        st.item_no,
        md.item_description,
        md.MPN AS mpn,
        st.on_hand_qty,
        st.on_hand_value_local,
        CASE WHEN sc.site_cur_per_gbp IS NOT NULL
             THEN st.on_hand_value_local / sc.site_cur_per_gbp
             ELSE NULL END AS on_hand_value_gbp,
        CASE WHEN sc.site_cur_per_gbp IS NOT NULL AND st.on_hand_qty > 0
             THEN (st.on_hand_value_local / sc.site_cur_per_gbp) / st.on_hand_qty
             ELSE NULL END AS unit_value_gbp,
        mm.movement_status,
        mm.average_issue_6,
        mm.average_issue_12,
        mm.average_quantity_6,
        mm.average_quantity_12,
        ms_sum.last_movement_date,
        ms_sum.movement_count_trailing_12mo,
        lmt.last_movement_type,
        NULLIF(ms.minimum_level, 0) AS minimum_level,
        ms.reorder_point,
        NULLIF(ms.maximum_level, 0) AS maximum_level,
        CASE
            WHEN NULLIF(ms.maximum_level, 0) IS NOT NULL AND st.on_hand_qty > NULLIF(ms.maximum_level, 0)
                THEN 'Overstock'
            WHEN NULLIF(ms.minimum_level, 0) IS NOT NULL AND st.on_hand_qty < NULLIF(ms.minimum_level, 0)
                THEN 'Understock'
            ELSE 'Within range'
        END AS stock_position
    FROM stock st
    LEFT JOIN site_ctx sc ON st.site = sc.site
    LEFT JOIN mdb_item_master md ON st.item_no = md.item_no
    LEFT JOIN mm_minmax mm ON mm.item_no = st.item_no AND mm.site = st.site
    LEFT JOIN ms_item_setup ms ON ms.item_no = st.item_no AND ms.site = st.site
    LEFT JOIN movement_summary ms_sum ON ms_sum.item_no = st.item_no AND ms_sum.site = st.site
    LEFT JOIN last_movement_type lmt  ON lmt.item_no = st.item_no AND lmt.site = st.site
),
/* For every (site, item_no) that qualifies as a SOURCE (slow/no-mover,stock on hand), find every other site with the same item that
qualifies as a TARGET (fast mover or understocked), and roll them up into one readable text field per source row. A genuine GROUP BY
self-join, not a per-row correlated subquery — this only touches the (small) population of items that appear at more than one site,
so it stays cheap despite being a self-join on 542K rows. */
transfer_targets_agg AS (
    SELECT
        src.site, src.item_no,
        GROUP_CONCAT(
            CONCAT(tgt.site_name, ' (', COALESCE(tgt.movement_status, 'n/a'), '/', tgt.stock_position,
                   ', qty: ', tgt.on_hand_qty, ')')
            ORDER BY tgt.site_name SEPARATOR '; '
        ) AS transfer_targets
    FROM enriched src
    JOIN enriched tgt
        ON src.item_no = tgt.item_no AND src.site <> tgt.site
    WHERE src.movement_status IN ('No Mover', 'Slow')
      AND src.on_hand_qty > 0
      AND (tgt.movement_status = 'Fast' OR tgt.stock_position = 'Understock')
    GROUP BY src.site, src.item_no
),
/* The mirror image: for every (site, item_no) that qualifies as a TARGET, find every other site with the same item that qualifies as a
SOURCE, rolled up the same way. */
transfer_sources_agg AS (
    SELECT
        tgt.site, tgt.item_no,
        GROUP_CONCAT(
            CONCAT(src.site_name, ' (', src.movement_status,
                   ', qty available: ', src.on_hand_qty, ')')
            ORDER BY src.site_name SEPARATOR '; '
        ) AS transfer_sources
    FROM enriched tgt
    JOIN enriched src
        ON tgt.item_no = src.item_no AND tgt.site <> src.site
    WHERE src.movement_status IN ('No Mover', 'Slow')
      AND src.on_hand_qty > 0
      AND (tgt.movement_status = 'Fast' OR tgt.stock_position = 'Understock')
    GROUP BY tgt.site, tgt.item_no
)
SELECT
    e.*,
    tta.transfer_targets,
    tsa.transfer_sources,
    CASE WHEN tta.transfer_targets IS NOT NULL THEN 1 ELSE 0 END AS is_transfer_source,
    CASE WHEN tsa.transfer_sources IS NOT NULL THEN 1 ELSE 0 END AS is_transfer_target
FROM enriched e
LEFT JOIN transfer_targets_agg tta ON tta.site = e.site AND tta.item_no = e.item_no
LEFT JOIN transfer_sources_agg tsa ON tsa.site = e.site AND tsa.item_no = e.item_no;














CREATE OR REPLACE VIEW v_kpi_summary AS
 
WITH unit_value AS (
    /* GBP unit value per site+item, current snapshot — the cost basis every value-based figure below builds on.*/
    SELECT
        m.site, m.item_no,
        SUM(m.unrestricted) AS on_hand_qty,
        SUM(m.value_unrestricted) AS on_hand_value_local,
        fx.rate AS site_cur_per_gbp,
        CASE WHEN fx.rate IS NOT NULL THEN SUM(m.value_unrestricted) / fx.rate ELSE NULL END AS on_hand_value_gbp,
        CASE WHEN fx.rate IS NOT NULL AND SUM(m.unrestricted) > 0
             THEN (SUM(m.value_unrestricted) / fx.rate) / SUM(m.unrestricted) ELSE NULL END AS unit_value_gbp
    FROM mobo25_stock m
    LEFT JOIN si_site s  ON m.site = s.site
    LEFT JOIN cx_currency_exchange fx ON fx.fm_cur = s.site_cur AND fx.to_cur = 'GBP'
    GROUP BY m.site, m.item_no, fx.rate
),
 
-- trailing-12mo turnover/DIO

trailing_bounds AS (
    SELECT MAX(posting_date) AS window_end,
           DATE_SUB(MAX(posting_date), INTERVAL 365 DAY) AS window_start
    FROM mobo15_movements WHERE posting_date IS NOT NULL
),
trailing_issued AS (
    SELECT
        SUM(-mo.quantity) AS total_issued_qty,
        SUM(-mo.quantity * uv.unit_value_gbp) AS total_cogs_gbp
    FROM mobo15_movements mo
    CROSS JOIN trailing_bounds b
    LEFT JOIN unit_value uv ON mo.item_no = uv.item_no AND mo.site = uv.site
    WHERE mo.mt IN ('471','472')
      AND mo.posting_date > b.window_start AND mo.posting_date <= b.window_end
),
 
-- raw stock-out rate (snapshot, no year dimension)
stockout_raw AS (
    SELECT
        COUNT(*) AS tracked_combos,
        SUM(CASE WHEN COALESCE(uv.on_hand_qty,0) <= 0 THEN 1 ELSE 0 END) AS stockout_combos,
        ROUND(100.0 * SUM(CASE WHEN COALESCE(uv.on_hand_qty,0) <= 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS stockout_rate_pct
    FROM (SELECT DISTINCT site, item_no FROM ms_item_setup WHERE deletion_indicator IS NULL OR deletion_indicator != 'X') t
    LEFT JOIN unit_value uv ON uv.site = t.site AND uv.item_no = t.item_no
),
 
-- excess inventory rate (snapshot, no year dimension)
excess_inv AS (
    SELECT
        SUM(CASE WHEN stock_position = 'Overstock' THEN on_hand_value_gbp ELSE 0 END) AS overstock_value_gbp,
        SUM(on_hand_value_gbp) AS total_value_gbp,
        ROUND(100.0 * SUM(CASE WHEN stock_position = 'Overstock' THEN on_hand_value_gbp ELSE 0 END)
              / NULLIF(SUM(on_hand_value_gbp),0), 2) AS excess_inventory_rate_pct
    FROM (
        SELECT
            uv.on_hand_value_gbp,
            CASE
                WHEN NULLIF(ms.maximum_level,0) IS NOT NULL AND uv.on_hand_qty > NULLIF(ms.maximum_level,0) THEN 'Overstock'
                WHEN NULLIF(ms.minimum_level,0) IS NOT NULL AND uv.on_hand_qty < NULLIF(ms.minimum_level,0) THEN 'Understock'
                ELSE 'Within range'
            END AS stock_position
        FROM mm_minmax mm
        JOIN unit_value uv ON uv.item_no = mm.item_no AND uv.site = mm.site
        LEFT JOIN ms_item_setup ms ON ms.item_no = mm.item_no AND ms.site = mm.site
        WHERE uv.on_hand_value_gbp IS NOT NULL
    ) scoped
),
 
-- calendar years present in mobo15, derived not hardcoded
year_calendar AS (
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
        SELECT YEAR(posting_date) AS yr, MIN(posting_date) AS first_date, MAX(posting_date) AS last_date
        FROM mobo15_movements WHERE posting_date IS NOT NULL GROUP BY YEAR(posting_date)
    )
    SELECT
        ys.yr,
        yd.first_date, yd.last_date,
        DATEDIFF(yd.last_date, yd.first_date) + 1 AS days_present,
        (yd.first_date > DATE(CONCAT(ys.yr,'-01-01')) OR yd.last_date < DATE(CONCAT(ys.yr,'-12-31'))) AS is_partial_year
    FROM year_seq ys JOIN year_data yd ON yd.yr = ys.yr
),
 
-- issued qty / COGS by year
issued_by_year AS (
    SELECT YEAR(mo.posting_date) AS yr,
           SUM(-mo.quantity) AS total_issued_qty,
           SUM(-mo.quantity * uv.unit_value_gbp) AS total_cogs_gbp
    FROM mobo15_movements mo
    LEFT JOIN unit_value uv ON mo.item_no = uv.item_no AND mo.site = uv.site
    WHERE mo.mt IN ('471','472') AND mo.posting_date IS NOT NULL
    GROUP BY YEAR(mo.posting_date)
),
 
-- demand-weighted stock-out by year
stockout_demand_by_year AS (
    SELECT
        d.yr,
        COUNT(*) AS demand_combos,
        SUM(CASE WHEN COALESCE(uv.on_hand_qty,0) <= 0 THEN 1 ELSE 0 END) AS stockout_combos,
        ROUND(100.0 * SUM(CASE WHEN COALESCE(uv.on_hand_qty,0) <= 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS stockout_rate_pct
    FROM (SELECT DISTINCT YEAR(posting_date) AS yr, site, item_no FROM mobo15_movements WHERE mt = '471' AND posting_date IS NOT NULL) d
    LEFT JOIN unit_value uv ON uv.site = d.site AND uv.item_no = d.item_no
    GROUP BY d.yr
),
 
-- reorder frequency by year (mean/median/max in one pass)
reorder_ranked AS (
    SELECT
        YEAR(posting_date) AS yr, item_no, site,
        COUNT(DISTINCT purchase_order) AS distinct_pos
    FROM mobo15_movements
    WHERE mt = '311' AND posting_date IS NOT NULL AND purchase_order IS NOT NULL
    GROUP BY YEAR(posting_date), item_no, site
),
reorder_by_year AS (
    SELECT
        yr, COUNT(*) AS reorder_freq_n, ROUND(AVG(distinct_pos),2) AS reorder_freq_mean, MAX(distinct_pos) AS reorder_freq_max,
        AVG(CASE WHEN rn IN (FLOOR((cnt+1)/2), CEIL((cnt+1)/2)) THEN distinct_pos END) AS reorder_freq_median
    FROM (
        SELECT yr, distinct_pos,
               ROW_NUMBER() OVER (PARTITION BY yr ORDER BY distinct_pos) AS rn,
               COUNT(*) OVER (PARTITION BY yr) AS cnt
        FROM reorder_ranked
    ) x
    GROUP BY yr
),
 
-- ---- cost per order by year (mean/median in one pass) ----
cpo_ranked AS (
    SELECT YEAR(mo.posting_date) AS yr, mo.purchase_order,
           SUM(mo.quantity * uv.unit_value_gbp) AS po_goods_value_gbp
    FROM mobo15_movements mo
    JOIN unit_value uv ON mo.item_no = uv.item_no AND mo.site = uv.site
    WHERE mo.mt = '311' AND mo.posting_date IS NOT NULL AND mo.purchase_order IS NOT NULL
    GROUP BY YEAR(mo.posting_date), mo.purchase_order
),
cpo_by_year AS (
    SELECT
        yr, COUNT(*) AS cpo_n, ROUND(AVG(po_goods_value_gbp),2) AS cpo_mean,
        ROUND(AVG(CASE WHEN rn IN (FLOOR((cnt+1)/2), CEIL((cnt+1)/2)) THEN po_goods_value_gbp END),2) AS cpo_median
    FROM (
        SELECT yr, po_goods_value_gbp,
               ROW_NUMBER() OVER (PARTITION BY yr ORDER BY po_goods_value_gbp) AS rn,
               COUNT(*) OVER (PARTITION BY yr) AS cnt
        FROM cpo_ranked WHERE po_goods_value_gbp IS NOT NULL
    ) x
    GROUP BY yr
),
 
-- transfer pairing
item_site_status AS (
    SELECT
        st.site, st.item_no, s.site_name, st.on_hand_qty,
        mm.movement_status,
        CASE
            WHEN NULLIF(ms.maximum_level,0) IS NOT NULL AND st.on_hand_qty > NULLIF(ms.maximum_level,0) THEN 'Overstock'
            WHEN NULLIF(ms.minimum_level,0) IS NOT NULL AND st.on_hand_qty < NULLIF(ms.minimum_level,0) THEN 'Understock'
            ELSE 'Within range'
        END AS stock_position
    FROM (
        SELECT site, item_no, SUM(unrestricted) AS on_hand_qty
        FROM mobo25_stock
        GROUP BY site, item_no
    ) st
    LEFT JOIN si_site s      ON st.site = s.site
    LEFT JOIN mm_minmax mm   ON mm.item_no = st.item_no AND mm.site = st.site
    LEFT JOIN ms_item_setup ms ON ms.item_no = st.item_no AND ms.site = st.site
),
transfer_pairs AS (
    SELECT
        src.item_no,
        src.site AS source_site, src.site_name AS source_site_name,
        src.movement_status AS source_movement_status, src.on_hand_qty AS source_stock_qty,
        tgt.site AS target_site, tgt.site_name AS target_site_name,
        tgt.movement_status AS target_movement_status, tgt.stock_position AS target_stock_position,
        tgt.on_hand_qty AS target_stock_qty
    FROM item_site_status src
    JOIN item_site_status tgt ON src.item_no = tgt.item_no AND src.site <> tgt.site
    WHERE src.movement_status IN ('No Mover','Slow') AND src.on_hand_qty > 0
      AND (tgt.movement_status = 'Fast' OR tgt.stock_position = 'Understock')
)
 
-- Row 1: trailing-12mo (1 row) 
SELECT
    'kpi_trailing_12mo' AS record_type, -1 AS period_sort_order,
    CONCAT('Trailing 12mo (', b.window_start, ' to ', b.window_end, ')') AS period_label,
    NULL AS is_partial_year, b.window_start, b.window_end,
    ti.total_issued_qty, ti.total_cogs_gbp,
    (SELECT SUM(on_hand_qty) FROM unit_value) AS current_on_hand_qty,
    (SELECT SUM(on_hand_value_gbp) FROM unit_value) AS current_inventory_value_gbp,
    ROUND(ti.total_issued_qty / NULLIF((SELECT SUM(on_hand_qty) FROM unit_value),0), 3) AS turnover_qty_ratio,
    ROUND(ti.total_cogs_gbp / NULLIF((SELECT SUM(on_hand_value_gbp) FROM unit_value),0), 3) AS turnover_value_ratio,
    ROUND((SELECT SUM(on_hand_value_gbp) FROM unit_value) / NULLIF(ti.total_cogs_gbp,0) * 365, 1) AS dio_days,
    sr.tracked_combos AS stockout_tracked_combos, sr.stockout_combos AS stockout_raw_combos, sr.stockout_rate_pct AS stockout_raw_pct,
    NULL AS stockout_demand_weighted_combos, NULL AS stockout_demand_weighted_pct,
    ei.overstock_value_gbp, ei.total_value_gbp AS excess_scope_total_value_gbp, ei.excess_inventory_rate_pct,
    NULL AS reorder_freq_n, NULL AS reorder_freq_mean, NULL AS reorder_freq_median, NULL AS reorder_freq_max,
    NULL AS cpo_n, NULL AS cpo_mean, NULL AS cpo_median,
    NULL AS tp_item_no, NULL AS tp_source_site, NULL AS tp_source_site_name, NULL AS tp_source_movement_status,
    NULL AS tp_source_stock_qty, NULL AS tp_target_site, NULL AS tp_target_site_name,
    NULL AS tp_target_movement_status, NULL AS tp_target_stock_position, NULL AS tp_target_stock_qty
FROM trailing_bounds b CROSS JOIN trailing_issued ti CROSS JOIN stockout_raw sr CROSS JOIN excess_inv ei
 
UNION ALL
 
-- ---- Rows 2-6: by year (5 rows) ----
SELECT
    'kpi_by_year' AS record_type, cal.yr AS period_sort_order, CAST(cal.yr AS CHAR) AS period_label,
    cal.is_partial_year, cal.first_date AS window_start, cal.last_date AS window_end,
    iss.total_issued_qty, iss.total_cogs_gbp,
    NULL AS current_on_hand_qty, NULL AS current_inventory_value_usd,
    NULL AS turnover_qty_ratio, NULL AS turnover_value_ratio, NULL AS dio_days,
    NULL AS stockout_tracked_combos, NULL AS stockout_raw_combos, NULL AS stockout_raw_pct,
    sw.stockout_combos AS stockout_demand_weighted_combos, sw.stockout_rate_pct AS stockout_demand_weighted_pct,
    NULL AS overstock_value_usd, NULL AS excess_scope_total_value_usd, NULL AS excess_inventory_rate_pct,
    ro.reorder_freq_n, ro.reorder_freq_mean, ro.reorder_freq_median, ro.reorder_freq_max,
    cp.cpo_n, cp.cpo_mean, cp.cpo_median,
    NULL AS tp_item_no, NULL AS tp_source_site, NULL AS tp_source_site_name, NULL AS tp_source_movement_status,
    NULL AS tp_source_stock_qty, NULL AS tp_target_site, NULL AS tp_target_site_name,
    NULL AS tp_target_movement_status, NULL AS tp_target_stock_position, NULL AS tp_target_stock_qty
FROM year_calendar cal
LEFT JOIN issued_by_year iss ON iss.yr = cal.yr
LEFT JOIN stockout_demand_by_year sw ON sw.yr = cal.yr
LEFT JOIN reorder_by_year ro ON ro.yr = cal.yr
LEFT JOIN cpo_by_year cp ON cp.yr = cal.yr
 
UNION ALL
 
-- ---- Rows 7-39: transfer pairings, structured (33 rows) ----
SELECT
    'transfer_pairing' AS record_type, 99 AS period_sort_order, 'Transfer pairing' AS period_label,
    NULL AS is_partial_year, NULL AS window_start, NULL AS window_end,
    NULL AS total_issued_qty, NULL AS total_cogs_gbp,
    NULL AS current_on_hand_qty, NULL AS current_inventory_value_gbp,
    NULL AS turnover_qty_ratio, NULL AS turnover_value_ratio, NULL AS dio_days,
    NULL AS stockout_tracked_combos, NULL AS stockout_raw_combos, NULL AS stockout_raw_pct,
    NULL AS stockout_demand_weighted_combos, NULL AS stockout_demand_weighted_pct,
    NULL AS overstock_value_gbp, NULL AS excess_scope_total_value_gbp, NULL AS excess_inventory_rate_pct,
    NULL AS reorder_freq_n, NULL AS reorder_freq_mean, NULL AS reorder_freq_median, NULL AS reorder_freq_max,
    NULL AS cpo_n, NULL AS cpo_mean, NULL AS cpo_median,
    tp.item_no AS tp_item_no, tp.source_site AS tp_source_site, tp.source_site_name AS tp_source_site_name,
    tp.source_movement_status AS tp_source_movement_status, tp.source_stock_qty AS tp_source_stock_qty,
    tp.target_site AS tp_target_site, tp.target_site_name AS tp_target_site_name,
    tp.target_movement_status AS tp_target_movement_status, tp.target_stock_position AS tp_target_stock_position,
    tp.target_stock_qty AS tp_target_stock_qty
FROM transfer_pairs tp
 
ORDER BY period_sort_order, period_label;





SELECT column_name FROM information_schema.columns
WHERE table_schema = 'your_schema_name'
  AND table_name = 'v_item_site_explorer'
  AND column_name IN ('last_movement_date', 'movement_count_trailing_12mo', 'last_movement_type');