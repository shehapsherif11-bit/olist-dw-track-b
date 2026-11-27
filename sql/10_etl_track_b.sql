/* Track B: dw.FactProductMonth.
   Only the product-months touched by this run are recomputed from FactSales.
   They are replaced, never added to, so a replay or a correction cannot double the totals.
   MonthStartDateKey = DateKey of the first day of the month (YYYYMM01).                    */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadFactProductMonth @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Replaced INT, @Written INT, @New INT;

    SELECT DISTINCT ProductKey, PurchaseDateKey / 100 * 100 + 1 AS MonthStartDateKey, IsTestData
    INTO #Affected
    FROM dw.FactSales WHERE LastRunID = @RunID;

    DELETE m
    FROM dw.FactProductMonth m
    JOIN #Affected a ON a.ProductKey = m.ProductKey AND a.MonthStartDateKey = m.MonthStartDateKey
                    AND a.IsTestData = m.IsTestData;
    SET @Replaced = @@ROWCOUNT;

    INSERT dw.FactProductMonth (ProductKey, MonthStartDateKey, IsTestData, SalesAmount, FreightAmount,
                                ItemCount, DistinctOrderCount, LastBatchID)
    SELECT f.ProductKey, a.MonthStartDateKey, f.IsTestData,
           SUM(f.ItemSalesAmount), SUM(f.FreightAmount), SUM(f.Quantity), COUNT(DISTINCT f.OrderID), @BatchID
    FROM dw.FactSales f
    JOIN #Affected a ON a.ProductKey = f.ProductKey
                    AND a.MonthStartDateKey = f.PurchaseDateKey / 100 * 100 + 1
                    AND a.IsTestData = f.IsTestData
    GROUP BY f.ProductKey, a.MonthStartDateKey, f.IsTestData;
    SET @Written = @@ROWCOUNT;
    SET @New = @Written - @Replaced;

    EXEC etl.usp_LogTable @RunID, N'dw.FactProductMonth', @New, @Replaced;
END;
GO
