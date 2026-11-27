/* Reconciliation of REAL data (IsTestData = 0). Run after B3 (and again after X1 if wanted). */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE TABLE #Check (CheckName VARCHAR(100), Result VARCHAR(4));

PRINT '=== 1. Source versus warehouse versus independent reference, per batch ===';
-- Reference values were calculated directly from the CSV files, outside SQL Server.
WITH Reference AS (
    SELECT * FROM (VALUES
     (1, 49556, 5962902.01, 958633.23),
     (2, 46219, 5511595.02, 926690.83),
     (3, 14105, 1706530.10, 306768.82)) v (BatchID, Items, Sales, Freight)),
Source AS (
    SELECT b.BatchID, COUNT(*) AS Items, SUM(CONVERT(DECIMAL(18,2), i.price)) AS Sales,
           SUM(CONVERT(DECIMAL(18,2), i.freight_value)) AS Freight
    FROM etl.Batch b
    JOIN src.Orders o ON o.order_status = N'delivered'
         AND CONVERT(DATETIME2(0), o.order_purchase_timestamp) >= b.PurchaseFrom
         AND CONVERT(DATETIME2(0), o.order_purchase_timestamp) <  b.PurchaseTo
    JOIN src.OrderItems i ON i.order_id = o.order_id
    GROUP BY b.BatchID),
Warehouse AS (
    SELECT b.BatchID, COUNT(*) AS Items, SUM(f.ItemSalesAmount) AS Sales, SUM(f.FreightAmount) AS Freight
    FROM etl.Batch b
    JOIN dw.FactSales f ON f.IsTestData = 0
         AND f.PurchaseTimestamp >= b.PurchaseFrom AND f.PurchaseTimestamp < b.PurchaseTo
    GROUP BY b.BatchID)
SELECT r.BatchID, s.Items AS SourceItems, w.Items AS DwItems, r.Items AS RefItems,
       s.Sales AS SourceSales, w.Sales AS DwSales, r.Sales AS RefSales,
       s.Freight AS SourceFreight, w.Freight AS DwFreight, r.Freight AS RefFreight,
       IIF(s.Items = w.Items AND w.Items = r.Items AND s.Sales = w.Sales AND w.Sales = r.Sales
           AND s.Freight = w.Freight AND w.Freight = r.Freight, 'PASS', 'FAIL') AS Result
INTO #Batch
FROM Reference r
LEFT JOIN Source s    ON s.BatchID = r.BatchID
LEFT JOIN Warehouse w ON w.BatchID = r.BatchID;
SELECT * FROM #Batch ORDER BY BatchID;
INSERT #Check SELECT CONCAT('Batch ', BatchID, ' reconciliation'), Result FROM #Batch;

PRINT '=== 2. Exclusions and warnings (rows not loaded must be explained here) ===';
SELECT i.BatchID, i.TableName, i.IssueType, i.Reason, COUNT(*) AS Issues
FROM etl.DataIssue i
JOIN etl.LoadLog l ON l.RunID = i.RunID AND l.Status = 'Success' AND l.IsForced = 0
GROUP BY i.BatchID, i.TableName, i.IssueType, i.Reason
ORDER BY i.BatchID, i.TableName, i.IssueType;

SELECT order_status, COUNT(*) AS OrdersNotInFactSales
FROM src.Orders
WHERE CONVERT(DATETIME2(0), order_purchase_timestamp) >= '2017-01-01'
  AND CONVERT(DATETIME2(0), order_purchase_timestamp) <  '2018-09-01'
  AND order_status <> N'delivered'
GROUP BY order_status ORDER BY COUNT(*) DESC;

PRINT '=== 3. FactProductMonth versus a full recompute from FactSales ===';
WITH Recompute AS (
    SELECT ProductKey, PurchaseDateKey / 100 * 100 + 1 AS MonthStartDateKey, IsTestData,
           SUM(ItemSalesAmount) AS SalesAmount, SUM(FreightAmount) AS FreightAmount,
           SUM(CAST(Quantity AS INT)) AS ItemCount, COUNT(DISTINCT OrderID) AS DistinctOrderCount
    FROM dw.FactSales
    GROUP BY ProductKey, PurchaseDateKey / 100 * 100 + 1, IsTestData),
Stored AS (
    SELECT ProductKey, MonthStartDateKey, IsTestData, SalesAmount, FreightAmount, ItemCount, DistinctOrderCount
    FROM dw.FactProductMonth),
Diff AS (
    (SELECT * FROM Recompute EXCEPT SELECT * FROM Stored)
    UNION ALL
    (SELECT * FROM Stored EXCEPT SELECT * FROM Recompute))
INSERT #Check SELECT 'FactProductMonth = recompute', IIF(COUNT(*) = 0, 'PASS', 'FAIL') FROM Diff;

INSERT #Check
SELECT 'Real product-month rows = 60640',
       IIF(COUNT(*) = 60640, 'PASS', 'FAIL') FROM dw.FactProductMonth WHERE IsTestData = 0;

INSERT #Check
SELECT 'vwCategoryMonth totals = FactSales (real)',
       IIF((SELECT SUM(SalesAmount) FROM mart.vwCategoryMonth WHERE IsTestData = 0) = SUM(ItemSalesAmount)
           AND (SELECT SUM(ItemCount) FROM mart.vwCategoryMonth WHERE IsTestData = 0) = COUNT(*), 'PASS', 'FAIL')
FROM dw.FactSales WHERE IsTestData = 0;

INSERT #Check
SELECT 'Jan-Aug 2017 and Jan-Aug 2018 sales = reference',
       IIF(SUM(IIF([Year] = 2017, SalesAmount, 0)) = 2993456.13
           AND SUM(IIF([Year] = 2018, SalesAmount, 0)) = 7218125.12, 'PASS', 'FAIL')
FROM mart.vwCategoryMonth WHERE IsTestData = 0 AND [Month] <= 8;

PRINT '=== 4. Why product order counts cannot be added (Track B trap) ===';
SELECT (SELECT SUM(DistinctOrderCount) FROM dw.FactProductMonth  WHERE IsTestData = 0) AS SumOfProductOrderCounts,
       (SELECT SUM(DistinctOrderCount) FROM mart.vwCategoryMonth WHERE IsTestData = 0) AS SumOfCategoryOrderCounts,
       (SELECT COUNT(DISTINCT OrderID)  FROM dw.FactSales        WHERE IsTestData = 0) AS DistinctOrders;

SELECT * FROM #Check;
IF EXISTS (SELECT 1 FROM #Check WHERE Result = 'FAIL')
    THROW 50104, 'Reconciliation test failed.', 1;
GO
