/* B2: incremental load with SCD Type 0, 1 and 2, including a failed attempt and a retry. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== BEFORE B2: seller, category labels, LAB facts ===';
SELECT SellerKey, SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent
FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01' ORDER BY ValidFrom;
SELECT 'star' AS Model, ProductKey, ProductID, CategoryCode, CategoryLabelEN
FROM dw.DimProduct WHERE CategoryCode = N'lab_training';
SELECT 'snowflake' AS Model, CategoryKey, CategoryCode, CategoryLabelEN
FROM sf.DimCategory WHERE CategoryCode = N'lab_training';
SELECT OrderID, ProductKey, SellerKey, ItemSalesAmount, FreightAmount FROM dw.FactSales WHERE IsTestData = 1;
GO
PRINT '=== FAILED ATTEMPT (simulated) ===';
BEGIN TRY
    EXEC etl.usp_RunBatch @BatchID = 2, @SimulateFailure = 1;
END TRY
BEGIN CATCH
    PRINT CONCAT('Expected error: ', ERROR_MESSAGE());
END CATCH;

SELECT RunID, BatchID, Status, ErrorText FROM etl.LoadLog WHERE BatchID = 2;

-- Nothing of B2 may remain after the rollback.
SELECT CheckName, Expected, Actual, IIF(Expected = Actual, 'PASS', 'FAIL') AS Result
FROM (VALUES
 ('Last successful batch', 1, (SELECT LastSuccessfulBatchID FROM etl.LoadState)),
 ('FactSales rows from B2', 0, (SELECT COUNT(*) FROM dw.FactSales WHERE InsertedBatchID = 2)),
 ('Staging orders of B2', 0, (SELECT COUNT(*) FROM stg.Orders WHERE BatchID = 2)),
 ('LAB seller versions', 1, (SELECT COUNT(*) FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01'))
) v (CheckName, Expected, Actual);

IF (SELECT LastSuccessfulBatchID FROM etl.LoadState) <> 1
   OR EXISTS (SELECT 1 FROM dw.FactSales WHERE InsertedBatchID = 2)
    THROW 50101, 'Rollback test failed.', 1;
GO
PRINT '=== RETRY ===';
EXEC etl.usp_RunBatch @BatchID = 2;
EXEC etl.usp_CheckBatch 2;
GO
PRINT '=== REPLAY B2: the Type 1 and Type 2 changes must create no extra rows ===';
EXEC etl.usp_RunBatch @BatchID = 2;              -- already successful: skipped
EXEC etl.usp_RunBatch @BatchID = 2, @Force = 1;  -- full processing again
EXEC etl.usp_CheckBatch 2;

IF EXISTS (SELECT 1 FROM etl.LoadLog l JOIN etl.LoadLogDetail d ON d.RunID = l.RunID
           WHERE l.BatchID = 2 AND l.IsForced = 1 AND d.RowsInserted + d.RowsUpdated <> 0)
    THROW 50109, 'B2 replay changed rows.', 1;
GO
PRINT '=== AFTER B2: seller, category labels, LAB facts ===';
SELECT SellerKey, SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent
FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01' ORDER BY ValidFrom;
SELECT 'star' AS Model, ProductKey, ProductID, CategoryCode, CategoryLabelEN
FROM dw.DimProduct WHERE CategoryCode = N'lab_training';
SELECT 'snowflake' AS Model, CategoryKey, CategoryCode, CategoryLabelEN
FROM sf.DimCategory WHERE CategoryCode = N'lab_training';
SELECT OrderID, ProductKey, SellerKey, ItemSalesAmount, FreightAmount FROM dw.FactSales WHERE IsTestData = 1;
SELECT BatchID, TableName, IssueType, SourceKey, Reason
FROM etl.DataIssue WHERE BatchID = 2 ORDER BY IssueID;
GO
