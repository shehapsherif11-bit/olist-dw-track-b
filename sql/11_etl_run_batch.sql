/* ETL step 6 and orchestration.
   EXEC etl.usp_RunBatch @BatchID = 1;

   - A batch that already succeeded is skipped (safe replay).
   - Batches must run in order.
   - @Force = 1 processes the LAST successful batch again. It must change nothing.
     Older batches cannot be forced: they could bring back an old price or label.
   - @SimulateFailure = 1 raises an error before the end, to test rollback and retry.
   - All data changes of a batch are one transaction. The log row survives a rollback.  */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- Stops the load when the warehouse does not match the accepted staging rows.
CREATE OR ALTER PROCEDURE etl.usp_Reconcile @BatchID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT i.OrderID, i.OrderItemID, i.ItemSalesAmount, i.FreightAmount
        FROM stg.vwOrderItems i
        JOIN stg.vwOrders o ON o.BatchID = i.BatchID AND o.OrderID = i.OrderID AND o.OrderStatus = 'delivered'
        WHERE i.BatchID = @BatchID
        EXCEPT
        SELECT OrderID, OrderItemID, ItemSalesAmount, FreightAmount FROM dw.FactSales)
        THROW 50020, 'Reconciliation failed: staged delivered items do not match FactSales.', 1;

    IF EXISTS (
        SELECT IsTestData, SUM(ItemSalesAmount), SUM(FreightAmount), SUM(CAST(Quantity AS INT))
        FROM dw.FactSales GROUP BY IsTestData
        EXCEPT
        SELECT IsTestData, SUM(SalesAmount), SUM(FreightAmount), SUM(ItemCount)
        FROM dw.FactProductMonth GROUP BY IsTestData)
        THROW 50021, 'Reconciliation failed: FactProductMonth totals do not match FactSales.', 1;
END;
GO
CREATE OR ALTER PROCEDURE etl.usp_RunBatch
    @BatchID INT, @Force BIT = 0, @SimulateFailure BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Last INT = (SELECT LastSuccessfulBatchID FROM etl.LoadState WHERE StateID = 1);
    DECLARE @RunID INT, @Staged INT, @Rejected INT;

    IF NOT EXISTS (SELECT 1 FROM etl.Batch WHERE BatchID = @BatchID)
        THROW 50030, 'Unknown BatchID. See etl.Batch.', 1;
    IF @Force = 1 AND @BatchID <> @Last
        THROW 50031, 'Only the last successful batch can be forced.', 1;
    IF @BatchID > @Last + 1
        THROW 50032, 'Batches must run in order. An earlier batch has not succeeded yet.', 1;

    IF @BatchID <= @Last AND @Force = 0
    BEGIN
        INSERT etl.LoadLog (BatchID, IsForced, StartTime, EndTime, Status, RowsStaged, RowsInserted, RowsUpdated, RowsRejected)
        VALUES (@BatchID, 0, SYSDATETIME(), SYSDATETIME(), 'Skipped', 0, 0, 0, 0);
        SELECT * FROM etl.LoadLog WHERE RunID = SCOPE_IDENTITY();
        RETURN;
    END;

    -- Loads are run one at a time. A row still marked Running belongs to a run that was cut off
    -- (for example the window was closed), so its transaction was already rolled back.
    UPDATE etl.LoadLog
    SET Status = 'Failed', EndTime = SYSDATETIME(), ErrorText = N'Interrupted before completion'
    WHERE Status = 'Running';

    INSERT etl.LoadLog (BatchID, IsForced, StartTime, Status)
    VALUES (@BatchID, @Force, SYSDATETIME(), 'Running');
    SET @RunID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC etl.usp_ExtractBatch            @BatchID, @RunID;
        EXEC etl.usp_ValidateBatch           @BatchID, @RunID;
        EXEC etl.usp_LoadDimProduct          @BatchID, @RunID;   -- dimensions before facts
        EXEC etl.usp_LoadDimCustomer         @BatchID, @RunID;
        EXEC etl.usp_LoadDimDeliveryLocation @BatchID, @RunID;
        EXEC etl.usp_LoadDimSeller           @BatchID, @RunID;
        EXEC etl.usp_LoadSnowflake           @RunID;
        EXEC etl.usp_LoadFactSales           @BatchID, @RunID;
        EXEC etl.usp_LoadFactProductMonth    @BatchID, @RunID;

        IF @SimulateFailure = 1
            THROW 50099, 'Simulated failure (test of rollback and retry).', 1;

        EXEC etl.usp_Reconcile @BatchID;

        SELECT @Staged = COUNT(*) FROM etl.vwBatchManifest WHERE BatchID = @BatchID;
        SELECT @Rejected = COUNT(*) FROM etl.DataIssue
        WHERE RunID = @RunID AND IssueType IN ('REJECT', 'DUPLICATE');

        -- The processed-batch marker moves only inside the successful transaction.
        UPDATE etl.LoadState SET LastSuccessfulBatchID = @BatchID, UpdatedAt = SYSDATETIME() WHERE StateID = 1;

        UPDATE etl.LoadLog
        SET Status = 'Success', EndTime = SYSDATETIME(), RowsStaged = @Staged, RowsRejected = @Rejected,
            RowsInserted = (SELECT SUM(RowsInserted) FROM etl.LoadLogDetail WHERE RunID = @RunID),
            RowsUpdated  = (SELECT SUM(RowsUpdated)  FROM etl.LoadLogDetail WHERE RunID = @RunID)
        WHERE RunID = @RunID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE etl.LoadLog
        SET Status = 'Failed', EndTime = SYSDATETIME(), ErrorText = ERROR_MESSAGE()
        WHERE RunID = @RunID;
        THROW;
    END CATCH;

    SELECT * FROM etl.LoadLog WHERE RunID = @RunID;
    SELECT TargetTable, RowsInserted, RowsUpdated, RowsRejected
    FROM etl.LoadLogDetail WHERE RunID = @RunID ORDER BY TargetTable;
END;
GO
