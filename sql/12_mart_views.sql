/* Track B reporting views (logical data mart). Both keep IsTestData:
   business reports use IsTestData = 0, test evidence uses IsTestData = 1. */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- Grain: category x purchase month x IsTestData.
-- Orders are counted from FactSales, because product order counts cannot be added.
CREATE OR ALTER VIEW mart.vwCategoryMonth AS
SELECT d.[Year], d.[Month], d.MonthStartDate,
       ISNULL(p.CategoryCode, N'(no category)') AS CategoryCode,
       p.CategoryLabelEN,
       f.IsTestData,
       SUM(f.ItemSalesAmount)        AS SalesAmount,
       SUM(f.FreightAmount)          AS FreightAmount,
       SUM(CAST(f.Quantity AS INT))  AS ItemCount,
       COUNT(DISTINCT f.OrderID)     AS DistinctOrderCount
FROM dw.FactSales f
JOIN dw.DimDate d    ON d.DateKey = f.PurchaseDateKey
JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY d.[Year], d.[Month], d.MonthStartDate, ISNULL(p.CategoryCode, N'(no category)'),
         p.CategoryLabelEN, f.IsTestData;
GO
-- Grain: product x purchase month x IsTestData, ranked by sales inside its category and month.
CREATE OR ALTER VIEW mart.vwProductRanking AS
SELECT d.[Year], d.[Month], d.MonthStartDate,
       ISNULL(p.CategoryCode, N'(no category)') AS CategoryCode,
       p.CategoryLabelEN, p.ProductKey, p.ProductID, m.IsTestData,
       m.SalesAmount, m.FreightAmount, m.ItemCount, m.DistinctOrderCount,
       SUM(m.SalesAmount) OVER (PARTITION BY m.MonthStartDateKey, m.IsTestData, p.CategoryCode) AS CategorySales,
       CAST(m.SalesAmount * 100.0
            / NULLIF(SUM(m.SalesAmount) OVER (PARTITION BY m.MonthStartDateKey, m.IsTestData, p.CategoryCode), 0)
            AS DECIMAL(9,2)) AS ShareOfCategoryPct,
       RANK() OVER (PARTITION BY m.MonthStartDateKey, m.IsTestData, p.CategoryCode
                    ORDER BY m.SalesAmount DESC) AS SalesRank
FROM dw.FactProductMonth m
JOIN dw.DimDate d    ON d.DateKey = m.MonthStartDateKey
JOIN dw.DimProduct p ON p.ProductKey = m.ProductKey;
GO
