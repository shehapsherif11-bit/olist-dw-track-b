# Data dictionary

## Technical columns

| Column | Where | Meaning |
|---|---|---|
| `BatchID` | `lab`, `stg` | 1 = B1, 2 = B2, 3 = B3, 4 = X1 |
| `ChangeSeq` | `lab`, `stg` | explicit LAB change = BatchID*1000+n; copied record = BatchID*1000 |
| `Operation` | `lab`, `stg` | `insert` = first delivery of the key, `update` = delivered before |
| `EffectiveAt` | `lab`, `stg` | business date from which a change is valid |
| `DupNo` | `stg` | number of a repeated row with the same source key |
| `IsTestData` | `stg`, facts | 1 = fictional LAB record, 0 = real Olist record |
| `ReceivedAt` | `stg` | time the row entered staging |
| `RejectReason` | `stg` | NULL = accepted |
| `original_seller_state` | `lab.Sellers`, `stg.Sellers` | extra column to test SCD Type 0 |
| `InsertedBatchID`, `LastBatchID`, `LastRunID`, `LoadedAt`, `UpdatedAt` | `dw` | load audit, separate from business dates |

`src`, `lab` and `stg` keep the column names of the CSV files.

## dw.DimDate - one row per day, plus key 0 (unknown)

| Column | Type | Meaning |
|---|---|---|
| `DateKey` (PK) | INT | `YYYYMMDD` |
| `DateValue` | DATE | calendar date |
| `Day`, `Month`, `Quarter`, `Year` | number | calendar parts |
| `MonthStartDate` | DATE | first day of the month |

## dw.DimProduct - one row per product

| Column | Type | Meaning |
|---|---|---|
| `ProductKey` (PK) | INT | surrogate key, 0 = unknown |
| `ProductID` (unique) | VARCHAR(64) | business key |
| `CategoryCode` | NVARCHAR(100) | source category code |
| `CategoryLabelEN` | NVARCHAR(100) | English label, SCD Type 1 |
| `WeightG` | INT | weight in grams |
| `LengthCm`, `HeightCm`, `WidthCm` | INT | size in centimetres |

## dw.DimCustomer - one row per person

| Column | Type | Meaning |
|---|---|---|
| `CustomerKey` (PK) | INT | surrogate key, 0 = unknown |
| `BusinessCustomerID` (unique) | VARCHAR(64) | `customer_unique_id` |

## dw.DimDeliveryLocation - one row per (City, State)

| Column | Type | Meaning |
|---|---|---|
| `DeliveryLocationKey` (PK) | INT | surrogate key, 0 = unknown |
| `City` | NVARCHAR(100) | normalized city |
| `State` | VARCHAR(10) | state code |

## dw.DimSeller - one row per seller version

| Column | Type | Meaning |
|---|---|---|
| `SellerKey` (PK) | INT | identifies one version, 0 = unknown |
| `SellerID` | VARCHAR(64) | business key; repeats across versions |
| `City`, `State` | text | location in this version (Type 2) |
| `OriginalSellerState` | VARCHAR(10) | first loaded state (Type 0) |
| `ValidFrom` | DATETIME2(0) | inclusive start |
| `ValidTo` | DATETIME2(0) | exclusive end, 9999-12-31 = open |
| `IsCurrent` | BIT | 1 for exactly one version per seller |

## dw.FactSales - one row per item of a delivered order

| Column | Type | Meaning |
|---|---|---|
| `SalesKey` (PK) | INT | row key |
| `OrderID`, `OrderItemID` (unique pair) | VARCHAR(64), INT | source identifiers |
| `PurchaseDateKey` | INT | FK to `DimDate` |
| `PurchaseTimestamp` | DATETIME2(0) | used to select the seller version |
| `ProductKey`, `CustomerKey`, `SellerKey`, `DeliveryLocationKey` | INT | FKs to dimensions |
| `ItemSalesAmount` | DECIMAL(18,2) | item price in BRL, additive |
| `FreightAmount` | DECIMAL(18,2) | recorded freight charge in BRL, additive |
| `Quantity` | TINYINT | always 1, additive |

## dw.FactProductMonth - product x month x IsTestData

| Column | Type | Meaning |
|---|---|---|
| `ProductKey` (PK) | INT | FK to `DimProduct` |
| `MonthStartDateKey` (PK) | INT | `DateKey` of the first day of the month |
| `IsTestData` (PK) | BIT | keeps test and real totals apart |
| `SalesAmount`, `FreightAmount` | DECIMAL(18,2) | additive |
| `ItemCount` | INT | additive |
| `DistinctOrderCount` | INT | not additive across products |

## sf

| Object | Columns |
|---|---|
| `sf.DimCategory` | `CategoryKey` (PK), `CategoryCode` (unique), `CategoryLabelEN` |
| `sf.DimProduct` | `ProductKey` (PK, same as `dw`), `ProductID`, `CategoryKey` (FK), weight and size |
| `sf.vwFactSales` | same sales rows as `dw.FactSales` |

## mart

| View | Grain | Content |
|---|---|---|
| `mart.vwCategoryMonth` | category x month x IsTestData | sales, freight, items, distinct orders |
| `mart.vwProductRanking` | product x month x IsTestData | sales, category share, rank inside category |

## etl

| Table | Content |
|---|---|
| `etl.Batch` | batch number, name, purchase-date range |
| `etl.LoadState` | last successfully processed batch |
| `etl.LoadLog` | one row per attempt: times, status, counts, error text |
| `etl.LoadLogDetail` | inserted, updated, rejected rows per target table |
| `etl.DataIssue` | rejected and duplicate rows, ignored Type 0 changes, warnings |
| `etl.vwBatchManifest` | batch, table, source key, operation, change sequence, effective time |
| `etl.vwReplaySnapshot` | row counts and totals compared before and after a replay |

## Procedures

| Procedure | Work |
|---|---|
| `etl.usp_RunBatch` | runs one batch in one transaction, writes the log |
| `etl.usp_ExtractBatch` | copies the batch records into `stg` |
| `etl.usp_ValidateBatch` | marks rejected rows and logs them |
| `etl.usp_LoadDimProduct`, `usp_LoadDimCustomer`, `usp_LoadDimDeliveryLocation` | dimensions |
| `etl.usp_LoadDimSeller` | SCD Type 0 and Type 2 |
| `etl.usp_LoadSnowflake` | `sf` tables |
| `etl.usp_LoadFactSales`, `etl.usp_LoadFactProductMonth` | facts |
| `etl.usp_Reconcile` | stops a load whose totals do not match |
| `etl.usp_LogTable` | saves row counts per table |
| `etl.usp_CheckBatch` | test: LAB expected versus actual results |

## Metric definitions not used by Track B

Late delivery (actual date after estimated date) and low rating (score 1 or 2) are defined in the brief. Track B reports do not use them.
