# Procurement Inventory Analytics
 
A SQL data pipeline and Power BI dashboard for procurement/inventory data across 73 sites in 21 countries - built from 8 disconnected, undocumented CSV/Excel exports into a governed schema, an Opportunity Dashboard that surfaces actionable stock-rebalancing recommendations, and a KPI framework built on validated, source-traceable calculations rather than assumed numbers.

> **Status**: Live. Core pipeline (8 raw tables → 2 consolidated views → Power BI) is deployed and refreshing on real data through mid-2026.

---

## Table of contents

- [What this project does](#what-this-project-does)
- [Architecture](#architecture)
- [Data sources](#data-sources)
- [The two core views](#the-two-core-views)
- [KPIs](#kpis)
- [Data quality — what was found and fixed](#data-quality--what-was-found-and-fixed)
- [Known limitations](#known-limitations)
- [Adding new data](#adding-new-data)
- [Dashboards](#dashboards)
---

## What this project does

Procurement teams need to answer three questions that raw ERP exports don't answer on their own:

1. **What do we have, and what's it worth?** - a currency-normalized view of stock across every site and country
2. **Is it moving?** - a Fast/Medium/Slow/No Mover classification per item, per site
3. **If it's not moving here, is it moving somewhere else?** - an automated recommendation engine that pairs idle stock at one site against genuine demand at another
This project answers all three from 8 raw source files, with every number traceable back to a specific SQL view - no hardcoded figures, no unexplained assumptions.

---

## Architecture

```
Raw exports (CSV/XLSX)
        │
        ▼
┌───────────────────────┐
│   load_new_data.py     │  cleans (mojibake, whitespace, ID artifacts,
│                         │  date formats), loads to MySQL, deduplicates
└───────────┬─────────────┘  on a full-row composite key, checks parity
            │
            ▼
┌─────────────────────────────────────────┐
│              MySQL (8 raw tables)         │
└───────────┬───────────────────┬───────────┘
            │                   │
            ▼                   ▼
  v_item_site_explorer   v_kpi_summary
  (542K rows — item+site   (39 rows — trailing-12mo,
   grain, movement status,  by-year, transfer pairings,
   transfer recommendations  stacked via record_type)
   built in as text)
            │                   │
            └─────────┬─────────┘
                       ▼
                  Power BI report
        (High-Level Overview / Opportunity
         Dashboard / KPI Summary)
```
 
Two views power the entire report - this was a deliberate design choice to minimize the Power BI import surface while keeping every calculation traceable to source SQL, not a DAX black box.
 
---
 
## Data sources
 
| File | Contents | Grain |
|---|---|---|
| `SI` (site info) | Site → name, currency, country | 1 row per site |
| `CD` (country dimension) | Country ID → name | 1 row per country |
| `CX` (currency exchange) | FX rates between currencies | 1 row per currency pair |
| `MDB` (item master) | Item → description, MPN | 1 row per item |
| `MM` (movement metrics) | Item+site → Fast/Medium/Slow/No Mover | 1 row per item+site |
| `MS` (MRP settings) | Item+site → min/max/reorder thresholds | 1 row per item+site |
| `MOBO25` (stock snapshot) | Current quantity/value on hand | 1 row per item+site+storage location |
| `MOBO15` (transaction log) | Every stock movement (issues, receipts, reversals) | 1 row per transaction |
 
---
 
## The two core views
 
**`v_item_site_explorer`** - 542,536 rows, one per item+site. Every stakeholder-facing question ("where is this item, is it moving, should we move it") is answerable from one row: quantity, value, movement status, stock position vs. MRP thresholds, and - computed directly into the row via a self-join - a human-readable transfer recommendation whenever the item is idle at one site with genuine demand at another.
 
**`v_kpi_summary`** - 39 rows, three shapes stacked via a `record_type` column: one trailing-12-month row (turnover, DIO - deliberately *not* split by year, since both divide by a fixed current-stock snapshot and a per-year split would imply a trend that isn't really there), five by-year rows (reorder frequency, cost per order, demand-weighted stock-out - genuinely comparable across years), and the full structured transfer-pairing table.
 
Neither view depends on a relationship to the other in Power BI - cross-referencing is done via DAX filter logic, avoiding an unnecessary many-to-many relationship.
 
---
 
## KPIs
 
| KPI | Calculable? | Notes |
|---|---|---|
| Inventory turnover (qty & value) | ✅ | Trailing 12mo, fixed window (not year-split — see above) |
| Days Inventory Outstanding | ✅ | Same fixed-window caveat |
| Stock-out rate | ✅ | demand-weighted |
| Reorder frequency | ✅ | Year-filterable, mean/median/max |
| Cost per order | ✅ | Goods value per PO, **not** admin/freight cost — that data doesn't exist in the source |
| Excess inventory rate | ✅ | Overstock value ÷ total value |
| Lead time | ❌ | No PO order-creation date in source data |
| Supplier performance | ❌ | No vendor/supplier entity anywhere in the 8 source tables |
| Inventory accuracy | ❌ | No physical/cycle-count records to compare against |
 
The three "not calculable" KPIs are flagged explicitly in the dashboard (a card literally reads "Not calculable") rather than backfilled with a fabricated estimate.
 
---
 
## Data quality - what was found and fixed
 
This project's development surfaced several real issues in the source data and in early versions of the pipeline itself. Documented here rather than silently patched, consistent with the project's overall approach:
 
- **68% of MRP min/max thresholds are exactly 0** - a placeholder, not a real capacity rule. Treated as "unset" (`NULLIF(x, 0)`) rather than a literal zero-limit, which was inflating false "Overstock" flags by roughly 2.4x.
- **`item_document` is not a unique transaction identifier over time** - the same document number was found recurring across 16 different dates with different items/quantities. A dedup key built on this single column alone silently rejected 196,410 genuinely new transactions as "already loaded." Fixed with a full-row composite key.
- **Mojibake, non-breaking spaces, and `.0` float-suffix artifacts** in MOBO15/MOBO25 text exports - fixed in a dedicated cleaning pass, with unrepairable cases explicitly flagged for manual review rather than guessed at.
- **`posting_date` required explicit conversion** from `DD/MM/YYYY` text to a real `DATE` type before insertion - missing this crashed every load attempt against a real MySQL schema (SQLite's leniency during earlier testing had masked the gap).
---
 
## Known limitations
 
- **9 of 21 countries have no FX rate on file** - their stock is tracked by quantity but excluded from GBP-normalized value totals, which are therefore a floor, not a complete figure.
- **"Within range" stock position is not the same as "verified healthy."** Because unset MRP thresholds default to this label, it includes both genuinely well-stocked items and items with no threshold configured at all.
- **Some non-zero MRP thresholds may still be unreliable** - extreme overstock ratios (some >10,000x) suggest possible unit-of-measure mismatches or stale configuration, not necessarily genuine overstock. Worth validating with source-system owners before acting on the most extreme flagged items.
---
 
## Adding new data
 
New data arrives as a full export. Workflow:
 
1. Create a new dated folder - **never overwrite a previous drop**
2. Move the new file(s) in
3. `python3 python/load_new_data.py <dated_folder>`
4. Check the printed row-count parity and data-quality-flag output before trusting the load
5. Refresh Power BI (manual, or on a schedule if configured)

---
 
## Dashboards
 
**High-Level Overview** - portfolio orientation: total value by country, top items by value, FX coverage gaps stated explicitly.
 
**Opportunity Dashboard** - search any item, see every site it's stocked at, and get a live "move stock from here to there" recommendation whenever it's idle at one site with demand elsewhere.
 
**KPI Summary** - the numbers above, with a year selector for the metrics where year-over-year comparison is actually valid.
 
---
