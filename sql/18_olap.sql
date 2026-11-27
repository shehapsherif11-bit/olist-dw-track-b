/* OLAP operations on the warehouse. Real data only (IsTestData = 0). Sales exclude freight (BRL). */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
-- Level of detail: month, then summed up to quarter, year and grand total.
PRINT '=== 1. ROLL-UP: month -> quarter -> year -> grand total ===';
-- GROUPING() = 1 marks a subtotal row, so it is not confused with an unknown value.
SELECT CASE WHEN GROUPING(d.[Year])    = 1 THEN 'Grand total'
            WHEN GROUPING(d.[Quarter]) = 1 THEN 'Year subtotal'
            WHEN GROUPING(d.[Month])   = 1 THEN 'Quarter subtotal'
            ELSE 'Month' END AS RowLevel,
       d.[Year], d.[Quarter], d.[Month],
       SUM(f.ItemSalesAmount) AS SalesAmount,
       COUNT(DISTINCT f.OrderID) AS Orders
FROM dw.FactSales f
JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
WHERE f.IsTestData = 0
GROUP BY ROLLUP (d.[Year], d.[Quarter], d.[Month])
ORDER BY GROUPING(d.[Year]), d.[Year], GROUPING(d.[Quarter]), d.[Quarter], GROUPING(d.[Month]), d.[Month];

-- Level of detail goes down: year -> quarter -> month, for the chosen year 2017.
PRINT '=== 2. DRILL-DOWN, level 1: sales per year ===';
SELECT d.[Year], SUM(f.ItemSalesAmount) AS SalesAmount
FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
WHERE f.IsTestData = 0
GROUP BY d.[Year] ORDER BY d.[Year];

PRINT '=== 2. DRILL-DOWN, level 2: quarters of 2017 ===';
SELECT d.[Year], d.[Quarter], SUM(f.ItemSalesAmount) AS SalesAmount
FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
WHERE f.IsTestData = 0 AND d.[Year] = 2017
GROUP BY d.[Year], d.[Quarter] ORDER BY d.[Quarter];

PRINT '=== 2. DRILL-DOWN, level 3: months of 2017 ===';
SELECT d.[Year], d.[Quarter], d.[Month], SUM(f.ItemSalesAmount) AS SalesAmount
FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
WHERE f.IsTestData = 0 AND d.[Year] = 2017
GROUP BY d.[Year], d.[Quarter], d.[Month] ORDER BY d.[Month];

PRINT '=== 2. DRILL-DOWN check: year = sum of quarters = sum of months ===';
WITH M AS (
    SELECT d.[Quarter], d.[Month], SUM(f.ItemSalesAmount) AS Sales
    FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
    WHERE f.IsTestData = 0 AND d.[Year] = 2017
    GROUP BY d.[Quarter], d.[Month]),
Q AS (SELECT [Quarter], SUM(Sales) AS Sales FROM M GROUP BY [Quarter]),
Y AS (SELECT SUM(f.ItemSalesAmount) AS Sales
      FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey = f.PurchaseDateKey
      WHERE f.IsTestData = 0 AND d.[Year] = 2017)
SELECT Y.Sales AS YearSales, (SELECT SUM(Sales) FROM Q) AS SumOfQuarters, (SELECT SUM(Sales) FROM M) AS SumOfMonths,
       IIF(Y.Sales = (SELECT SUM(Sales) FROM Q) AND Y.Sales = (SELECT SUM(Sales) FROM M), 'PASS', 'FAIL') AS Result
FROM Y;

-- Level of detail: category. One dimension value is fixed (year = 2017).
PRINT '=== 3. SLICE: one year (2017), by category ===';
SELECT p.CategoryLabelEN, SUM(f.ItemSalesAmount) AS SalesAmount, SUM(f.FreightAmount) AS FreightAmount,
       SUM(CAST(f.Quantity AS INT)) AS Items, COUNT(DISTINCT f.OrderID) AS Orders
FROM dw.FactSales f
JOIN dw.DimDate d    ON d.DateKey = f.PurchaseDateKey
JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
WHERE f.IsTestData = 0 AND d.[Year] = 2017
GROUP BY p.CategoryLabelEN ORDER BY SalesAmount DESC;

-- Level of detail: month x category x delivery state. Several dimensions are filtered.
PRINT '=== 4. DICE: selected years, months, categories and delivery states ===';
SELECT d.[Year], d.[Month], p.CategoryLabelEN, l.State AS DeliveryState,
       SUM(f.ItemSalesAmount) AS SalesAmount, COUNT(DISTINCT f.OrderID) AS Orders
FROM dw.FactSales f
JOIN dw.DimDate d             ON d.DateKey = f.PurchaseDateKey
JOIN dw.DimProduct p          ON p.ProductKey = f.ProductKey
JOIN dw.DimDeliveryLocation l ON l.DeliveryLocationKey = f.DeliveryLocationKey
WHERE f.IsTestData = 0
  AND d.[Year] IN (2017, 2018)
  AND d.[Month] IN (1, 2)
  AND p.CategoryCode IN (N'beleza_saude', N'informatica_acessorios')
  AND l.State IN ('SP', 'RJ')
GROUP BY d.[Year], d.[Month], p.CategoryLabelEN, l.State
ORDER BY d.[Year], d.[Month], p.CategoryLabelEN, l.State;

-- Level of detail: category (rows) x month (columns), year 2017.
PRINT '=== 5. PIVOT: sales of 2017, categories as rows and months as columns ===';
SELECT CategoryLabelEN,
       [1] AS Jan, [2] AS Feb, [3] AS Mar, [4] AS Apr, [5] AS May, [6] AS Jun,
       [7] AS Jul, [8] AS Aug, [9] AS Sep, [10] AS Oct, [11] AS Nov, [12] AS Dec
FROM (
    SELECT p.CategoryLabelEN, d.[Month], f.ItemSalesAmount
    FROM dw.FactSales f
    JOIN dw.DimDate d    ON d.DateKey = f.PurchaseDateKey
    JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
    WHERE f.IsTestData = 0 AND d.[Year] = 2017
) AS Source
PIVOT (SUM(ItemSalesAmount) FOR [Month] IN ([1],[2],[3],[4],[5],[6],[7],[8],[9],[10],[11],[12])) AS Pivoted
ORDER BY CategoryLabelEN;
GO
