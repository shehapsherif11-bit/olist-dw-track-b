/* Creates etl.usp_CheckBatch: expected versus actual LAB results after a batch.
   EXEC etl.usp_CheckBatch 1;   Run it directly after that batch. It fails if a check fails. */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE etl.usp_CheckBatch @BatchID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Latest payment value of each LAB payment that has arrived so far.
    DECLARE @Payments DECIMAL(18,2) = (
        SELECT SUM(PaymentValue) FROM (
            SELECT PaymentValue,
                   ROW_NUMBER() OVER (PARTITION BY OrderID, PaymentSequential ORDER BY BatchID DESC, ChangeSeq DESC) AS rn
            FROM stg.vwPayments WHERE IsTestData = 1 AND BatchID <= @BatchID) x
        WHERE rn = 1);

    WITH Expected AS (
        SELECT * FROM (VALUES
         (1, 1, 100.00, 10.00, 1, 100.00,   0.00, 110.00, 0, N'Traning'),
         (2, 2, 300.00, 30.00, 2, 100.00, 200.00, 330.00, 1, N'Training'),
         (3, 3, 610.00, 60.00, 2, 410.00, 200.00, 670.00, 1, N'Training'),
         (4, 4, 660.00, 65.00, 2, 460.00, 200.00, 725.00, 1, N'Training')
        ) v (BatchID, FactRows, Sales, Freight, SellerVersions, SalesSP, SalesRJ, Payments, Scd0Logs, Label)),
    Lab AS (
        SELECT f.ItemSalesAmount, f.FreightAmount, s.State
        FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
        WHERE f.IsTestData = 1),
    Checks AS (
        SELECT v.CheckName, v.Expected, v.Actual
        FROM Expected e
        CROSS APPLY (VALUES
         (N'LAB FactSales rows',   CONCAT(e.FactRows, ''),       CONCAT((SELECT COUNT(*) FROM Lab), '')),
         (N'LAB sales (BRL)',      CONCAT(e.Sales, ''),          CONCAT((SELECT SUM(ItemSalesAmount) FROM Lab), '')),
         (N'LAB freight (BRL)',    CONCAT(e.Freight, ''),        CONCAT((SELECT SUM(FreightAmount) FROM Lab), '')),
         (N'LAB seller versions',  CONCAT(e.SellerVersions, ''), CONCAT((SELECT COUNT(*) FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01'), '')),
         (N'LAB sales, seller SP', CONCAT(e.SalesSP, ''),        CONCAT((SELECT ISNULL(SUM(ItemSalesAmount), 0.00) FROM Lab WHERE State = 'SP'), '')),
         (N'LAB sales, seller RJ', CONCAT(e.SalesRJ, ''),        CONCAT((SELECT ISNULL(SUM(ItemSalesAmount), 0.00) FROM Lab WHERE State = 'RJ'), '')),
         (N'LAB payments (BRL)',   CONCAT(e.Payments, ''),       CONCAT(@Payments, '')),
         (N'LAB customers in DimCustomer', N'1',                 CONCAT((SELECT COUNT(*) FROM dw.DimCustomer WHERE BusinessCustomerID = 'LAB_CUSTOMER_01'), '')),
         (N'SCD0 attempts logged', CONCAT(e.Scd0Logs, ''),       CONCAT((SELECT COUNT(*) FROM etl.DataIssue WHERE IssueType = 'SCD0_IGNORED' AND SourceKey = N'LAB_SELLER_01'), '')),
         (N'OriginalSellerState on all versions', N'SP',         (SELECT CONCAT(MIN(OriginalSellerState), IIF(MIN(OriginalSellerState) = MAX(OriginalSellerState), '', '+' + MAX(OriginalSellerState))) FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01')),
         (N'Category label (star)',       e.Label, (SELECT MIN(CategoryLabelEN) FROM dw.DimProduct WHERE CategoryCode = N'lab_training')),
         (N'Category label (star, max)',  e.Label, (SELECT MAX(CategoryLabelEN) FROM dw.DimProduct WHERE CategoryCode = N'lab_training')),
         (N'Category label (snowflake)',  e.Label, (SELECT CategoryLabelEN FROM sf.DimCategory WHERE CategoryCode = N'lab_training')),
         (N'LAB FactProductMonth sales',  CONCAT(e.Sales, ''),    CONCAT((SELECT SUM(SalesAmount) FROM dw.FactProductMonth WHERE IsTestData = 1), '')),
         (N'LAB FactProductMonth items',  CONCAT(e.FactRows, ''), CONCAT((SELECT SUM(ItemCount) FROM dw.FactProductMonth WHERE IsTestData = 1), '')),
         (N'Last successful batch',       CONCAT(@BatchID, ''),   CONCAT((SELECT LastSuccessfulBatchID FROM etl.LoadState), ''))
        ) v (CheckName, Expected, Actual)
        WHERE e.BatchID = @BatchID)
    SELECT @BatchID AS BatchID, CheckName, Expected, Actual,
           IIF(Expected = Actual, 'PASS', 'FAIL') AS Result
    INTO #Result
    FROM Checks;

    SELECT * FROM #Result;

    IF NOT EXISTS (SELECT 1 FROM #Result) OR EXISTS (SELECT 1 FROM #Result WHERE Result = 'FAIL')
        THROW 50100, 'LAB batch check failed.', 1;
END;
GO
