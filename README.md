# Olist Data Warehouse - Track B (Products and categories)

Business Intelligence course project. SQL Server data warehouse built from the Olist e-commerce dataset.

## Data source

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce),
license **CC BY-NC-SA 4.0**. Credit: Olist.

- Download date: 27 November 2026
- Dataset version: not recorded
- The raw CSV files are not committed. Put them in the `Data` folder. Do not edit them.

SHA-256 of the files used:

| File | SHA-256 |
|---|---|
| olist_customers_dataset.csv | `983a422239e1712ded753b3bf9ecf47dc73f144d306029dcfa99e70a226883d2` |
| olist_order_items_dataset.csv | `0bc4d068c4fe38cbb01bd90e8746e3c613fe7b4baef75fab7b0e329701c3e279` |
| olist_order_payments_dataset.csv | `4f713964f2815dbbaa40b9488268c55aac3627bfce5aa96cf58d1f3616de3cc0` |
| olist_order_reviews_dataset.csv | `012b61c7593e34f51fa614efdf802b9c7056ce6aae5307ddb93236e7cfc797d7` |
| olist_orders_dataset.csv | `8df58ef3d2d7e9944010f7beecd9b75367f5588ec6e3c91cec19ae3345ef9ecf` |
| olist_products_dataset.csv | `3e6569628a17fbc75fd206ee357b59e20364b9afa90f5b6cd5b4d624c58aa9cc` |
| olist_sellers_dataset.csv | `1f643d2b950373b85735e7794b20986f528d7a000432e7c6f9bcbb44d0846a0e` |
| product_category_name_translation.csv | `a81f0d1f27b27e7293f761bc79e3ce8f348ee39c4b3ed3e49bde38f478586278` |

The geolocation file is optional and is not used.

### Import settings (`sql/02_source_import.sql`)

| Setting | Value |
|---|---|
| Method | `BULK INSERT` into text columns, first row skipped |
| Format | `FORMAT = 'CSV'`, field quote `"`, separator `,` |
| Encoding | UTF-8 (`CODEPAGE = '65001'`) |
| Row end | `0x0d0a` for reviews and category translation, `0x0a` for the others |

## Requirements

- SQL Server and SSMS, Windows authentication. The scripts were run with `sqlcmd` on SQL Server 2022 Express.
- If SSMS shows a certificate error, select **Trust server certificate**.
- Change `@DataPath` in `sql/02_source_import.sql` if the project is in another folder.
- Free memory: close heavy programs before a load. With only about 300 MB of free RAM, SQL Server
  stops and waits for memory (wait type `RESOURCE_SEMAPHORE`). With about 1 GB or more free it ran normally.

## Run order

In SSMS, open and execute each script in this order:

| Step | Script | Purpose |
|---|---|---|
| 0 | `sql/00_reset.sql` | Reset only: **deletes** `OlistDW_Project` |
| 1 | `sql/01_database_schemas.sql` | Database and schemas |
| 2 | `sql/02_source_import.sql` | Import CSV files into `src` |
| 3 | `sql/03_staging_etl_tables.sql` | `stg`, `lab`, `etl` tables |
| 4 | `sql/04_prepare_batches.sql` | Batches B1-B3 and LAB records |
| 5 | `sql/05_dw_sf_tables.sql` | Star, track table, snowflake, calendar |
| 6 | `sql/06_etl_extract_validate.sql` ... `sql/11_etl_run_batch.sql` | ETL procedures (06, 07, 08, 09, 10, 11) |
| 7 | `sql/12_mart_views.sql` | Reporting views |
| 8 | `tests/T1_check_batch.sql` | LAB check procedure |
| 9 | `sql/13_run_B1.sql` | Initial load |
| 10 | `sql/14_run_B2.sql` | Incremental load, SCD, failure and retry |
| 11 | `sql/15_run_B3_replay.sql` | Late order, correction, replay |
| 12 | `tests/T2` ... `tests/T5` | Reconciliation, SCD, integrity, data quality |
| 13 | `sql/19_snowflake_compare.sql` | Star versus snowflake |
| 14 | `sql/18_olap.sql` | Roll-up, drill-down, slice, dice, pivot |
| 15 | `sql/16_run_X1.sql` | Track B update test and replay |
| 16 | `sql/17_track_b_queries.sql` | Three business queries |
| 17 | `sql/20_batch_manifest.sql` | Batch manifest |

Run the load scripts (13, 14, 15, 16) **once each after a reset**. Script 14 tests a failed B2 run,
so it fails on purpose with an error if B2 is already loaded.

Or run everything from PowerShell in the project folder (outputs go to `results/`):

```powershell
powershell -ExecutionPolicy Bypass -File .\run_all.ps1 -Reset
```

## Documents and evidence

| File | Content |
|---|---|
| [docs/design.md](docs/design.md) | Architecture, star and snowflake, mapping, grain, SCD, data rules |
| [docs/data_dictionary.md](docs/data_dictionary.md) | Tables and columns |
| [docs/batch_manifest.md](docs/batch_manifest.md) | Batches and LAB records |
| [docs/Olist_DW_Track_B_Report.pdf](docs/Olist_DW_Track_B_Report.pdf) | Project report (PDF) |
| [docs/report.md](docs/report.md) | Short report (text version) |
| `docs/database_guide.html` | Arabic guide to all tables (open in a web browser) |
| [Data flow](docs/diagrams/data_flow.svg), [star](docs/diagrams/star_schema.svg), [snowflake](docs/diagrams/snowflake_schema.svg) | Diagrams as pictures |
| `results/` | Output of every script from the last full run |

## Test data

Records that start with `LAB_` are fictional. They have `IsTestData = 1` and exist only to test the loads.
Business reports use `IsTestData = 0`. The LAB seller relocation is simulated and is not real seller history.
