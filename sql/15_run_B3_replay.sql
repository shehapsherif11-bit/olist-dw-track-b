/* B3: late order + correction. Then replay B3 twice: normal (skipped) and forced (no change). */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
EXEC etl.usp_RunBatch @BatchID = 3;
EXEC etl.usp_CheckBatch 3;

SELECT f.OrderID, f.PurchaseTimestamp, f.InsertedBatchID, f.LastBatchID, f.SellerKey, s.State AS SellerState,
       f.ItemSalesAmount, f.FreightAmount
FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
WHERE f.IsTestData = 1 ORDER BY f.OrderID;
GO
PRINT '=== REPLAY B3 ===';
GO
-- Row counts and totals that a replay must not change.
CREATE OR ALTER VIEW etl.vwReplaySnapshot AS
    SELECT v.Item, v.Value FROM (VALUES
     ('DimProduct rows',          (SELECT COUNT(*) FROM dw.DimProduct)),
     ('DimCustomer rows',         (SELECT COUNT(*) FROM dw.DimCustomer)),
     ('DimDeliveryLocation rows', (SELECT COUNT(*) FROM dw.DimDeliveryLocation)),
     ('DimSeller rows',           (SELECT COUNT(*) FROM dw.DimSeller)),
     ('FactSales rows',           (SELECT COUNT(*) FROM dw.FactSales)),
     ('FactSales sales',          (SELECT SUM(ItemSalesAmount) FROM dw.FactSales)),
     ('FactSales freight',        (SELECT SUM(FreightAmount) FROM dw.FactSales)),
     ('FactProductMonth rows',    (SELECT COUNT(*) FROM dw.FactProductMonth)),
     ('FactProductMonth sales',   (SELECT SUM(SalesAmount) FROM dw.FactProductMonth)),
     ('FactProductMonth orders',  (SELECT SUM(DistinctOrderCount) FROM dw.FactProductMonth)),
     ('sf.DimCategory rows',      (SELECT COUNT(*) FROM sf.DimCategory)),
     ('sf.DimProduct rows',       (SELECT COUNT(*) FROM sf.DimProduct)),
     ('Staged records of B3',     (SELECT COUNT(*) FROM etl.vwBatchManifest WHERE BatchID = 3))
    ) v (Item, Value);
GO
CREATE TABLE #Snapshot (Step VARCHAR(10), Item VARCHAR(40), Value DECIMAL(18,2));

INSERT #Snapshot SELECT 'before', Item, Value FROM etl.vwReplaySnapshot;
EXEC etl.usp_RunBatch @BatchID = 3;              -- already successful: skipped
EXEC etl.usp_RunBatch @BatchID = 3, @Force = 1;  -- full processing again: must change nothing
INSERT #Snapshot SELECT 'after', Item, Value FROM etl.vwReplaySnapshot;

SELECT b.Item, b.Value AS BeforeReplay, a.Value AS AfterReplay,
       IIF(a.Value = b.Value, 'PASS', 'FAIL') AS Result
FROM #Snapshot b JOIN #Snapshot a ON a.Item = b.Item AND a.Step = 'after'
WHERE b.Step = 'before';

SELECT l.RunID, d.TargetTable, d.RowsInserted, d.RowsUpdated
FROM etl.LoadLog l JOIN etl.LoadLogDetail d ON d.RunID = l.RunID
WHERE l.BatchID = 3 AND l.IsForced = 1 ORDER BY l.RunID, d.TargetTable;

IF EXISTS (SELECT 1 FROM #Snapshot b JOIN #Snapshot a ON a.Item = b.Item AND a.Step = 'after'
           WHERE b.Step = 'before' AND a.Value <> b.Value)
   OR EXISTS (SELECT 1 FROM etl.LoadLog l JOIN etl.LoadLogDetail d ON d.RunID = l.RunID
              WHERE l.BatchID = 3 AND l.IsForced = 1 AND d.RowsInserted + d.RowsUpdated <> 0)
    THROW 50102, 'Replay test failed.', 1;

EXEC etl.usp_CheckBatch 3;
GO
