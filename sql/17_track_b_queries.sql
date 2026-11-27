/* Track B: three business queries. Real data only (IsTestData = 0).
   Sales = item price. It excludes freight and is not profit. Currency: BRL.
   Only delivered orders. The data ends in August 2018.                      */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== Q1a. Which categories contribute most to monthly sales? Top 5 per month ===';
-- Level of detail: month x category.
WITH MonthShare AS (
    SELECT [Year], [Month], CategoryLabelEN, SalesAmount,
           CAST(SalesAmount * 100.0 / NULLIF(SUM(SalesAmount) OVER (PARTITION BY [Year], [Month]), 0)
                AS DECIMAL(9,2)) AS ShareOfMonthPct,
           RANK() OVER (PARTITION BY [Year], [Month] ORDER BY SalesAmount DESC) AS SalesRank
    FROM mart.vwCategoryMonth
    WHERE IsTestData = 0)
SELECT [Year], [Month], SalesRank, CategoryLabelEN, SalesAmount, ShareOfMonthPct
FROM MonthShare
WHERE SalesRank <= 5
ORDER BY [Year], [Month], SalesRank;

PRINT '=== Q1b. Whole period: top 10 categories and how many months each was in the top 5 ===';
WITH MonthRank AS (
    SELECT CategoryLabelEN, SalesAmount,
           RANK() OVER (PARTITION BY [Year], [Month] ORDER BY SalesAmount DESC) AS SalesRank
    FROM mart.vwCategoryMonth
    WHERE IsTestData = 0)
SELECT TOP (10) CategoryLabelEN, SUM(SalesAmount) AS SalesAmount,
       CAST(SUM(SalesAmount) * 100.0 / NULLIF(SUM(SUM(SalesAmount)) OVER (), 0) AS DECIMAL(9,2)) AS ShareOfAllPct,
       SUM(IIF(SalesRank <= 5, 1, 0)) AS MonthsInTop5
FROM MonthRank
GROUP BY CategoryLabelEN
ORDER BY SUM(SalesAmount) DESC;

PRINT '=== Q2. Which products have the largest share of sales inside their category? (whole period) ===';
-- Level of detail: category, with its leading product.
-- Read ProductsInCategory: a category with few products has a high share by nature.
WITH ProductSales AS (
    SELECT CategoryCode, CategoryLabelEN, ProductID, SUM(SalesAmount) AS SalesAmount
    FROM mart.vwProductRanking
    WHERE IsTestData = 0
    GROUP BY CategoryCode, CategoryLabelEN, ProductID),
Shares AS (
    SELECT *,
           SUM(SalesAmount) OVER (PARTITION BY CategoryCode) AS CategorySales,
           COUNT(*)         OVER (PARTITION BY CategoryCode) AS ProductsInCategory,
           RANK()           OVER (PARTITION BY CategoryCode ORDER BY SalesAmount DESC) AS RankInCategory
    FROM ProductSales)
SELECT CategoryLabelEN, ProductID, SalesAmount, CategorySales, ProductsInCategory,
       CAST(SalesAmount * 100.0 / NULLIF(CategorySales, 0) AS DECIMAL(9,2)) AS ShareOfCategoryPct
FROM Shares
WHERE RankInCategory = 1
ORDER BY CategorySales DESC;

PRINT '=== Q3. Which categories gained or lost sales? Jan-Aug 2017 versus Jan-Aug 2018 ===';
-- Matching periods: the same eight months in both years.
WITH Periods AS (
    SELECT CategoryLabelEN,
           SUM(IIF([Year] = 2017, SalesAmount, 0)) AS Sales2017,
           SUM(IIF([Year] = 2018, SalesAmount, 0)) AS Sales2018
    FROM mart.vwCategoryMonth
    WHERE IsTestData = 0 AND [Month] BETWEEN 1 AND 8
    GROUP BY CategoryLabelEN)
SELECT CategoryLabelEN, Sales2017, Sales2018, Sales2018 - Sales2017 AS ChangeAmount,
       CAST((Sales2018 - Sales2017) * 100.0 / NULLIF(Sales2017, 0) AS DECIMAL(12,2)) AS ChangePct,
       CASE WHEN Sales2017 = 0 THEN 'No 2017 base'
            WHEN Sales2018 > Sales2017 THEN 'Gained'
            WHEN Sales2018 < Sales2017 THEN 'Lost'
            ELSE 'No change' END AS Direction
FROM Periods
ORDER BY ChangeAmount DESC;
GO
