/* The same category-sales question on both models. The results must be equal.
   Star:      FactSales -> DimProduct                      (1 join, label repeated per product)
   Snowflake: vwFactSales -> DimProduct -> DimCategory     (2 joins, label stored once)
   This script compares results and structure only. It does not measure speed. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
SELECT f.IsTestData, p.CategoryLabelEN, SUM(f.ItemSalesAmount) AS SalesAmount, COUNT(*) AS Items
INTO #Star
FROM dw.FactSales f
JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY f.IsTestData, p.CategoryLabelEN;

SELECT f.IsTestData, c.CategoryLabelEN, SUM(f.ItemSalesAmount) AS SalesAmount, COUNT(*) AS Items
INTO #Snowflake
FROM sf.vwFactSales f
JOIN sf.DimProduct p  ON p.ProductKey = f.ProductKey
JOIN sf.DimCategory c ON c.CategoryKey = p.CategoryKey
GROUP BY f.IsTestData, c.CategoryLabelEN;

PRINT '=== Category sales side by side ===';
SELECT s.IsTestData, s.CategoryLabelEN, s.SalesAmount AS StarSales, n.SalesAmount AS SnowflakeSales,
       s.Items AS StarItems, n.Items AS SnowflakeItems
FROM #Star s
FULL JOIN #Snowflake n ON n.IsTestData = s.IsTestData AND n.CategoryLabelEN = s.CategoryLabelEN
ORDER BY s.IsTestData, s.SalesAmount DESC;

DECLARE @OnlyStar INT = (SELECT COUNT(*) FROM (SELECT * FROM #Star EXCEPT SELECT * FROM #Snowflake) x);
DECLARE @OnlySnow INT = (SELECT COUNT(*) FROM (SELECT * FROM #Snowflake EXCEPT SELECT * FROM #Star) x);

SELECT @OnlyStar AS RowsOnlyInStar, @OnlySnow AS RowsOnlyInSnowflake,
       IIF(@OnlyStar = 0 AND @OnlySnow = 0, 'PASS', 'FAIL') AS Result;

PRINT '=== Repeated attributes and update steps (LAB category) ===';
SELECT 'star: rows that store the label' AS Measure, COUNT(*) AS RowsCount
FROM dw.DimProduct WHERE CategoryCode = N'lab_training'
UNION ALL
SELECT 'snowflake: rows that store the label', COUNT(*) FROM sf.DimCategory WHERE CategoryCode = N'lab_training';

SELECT l.BatchID, d.TargetTable, d.RowsInserted, d.RowsUpdated
FROM etl.LoadLog l JOIN etl.LoadLogDetail d ON d.RunID = l.RunID
WHERE l.BatchID = 2 AND l.Status = 'Success' AND l.IsForced = 0
  AND d.TargetTable IN (N'dw.DimProduct', N'sf.DimCategory')
ORDER BY d.TargetTable;

IF @OnlyStar <> 0 OR @OnlySnow <> 0
    THROW 50108, 'Star and snowflake results differ.', 1;
GO
