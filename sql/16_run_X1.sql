/* Track B update test X1 (batch 4). Run after B1-B3.
   A new LAB order purchased on 2017-12-10 arrives late: price 50, freight 5.
   Expected: December 2017 product summary gains 50 sales and 1 item. Replay adds nothing. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
-- X1 source change records (same values every time).
DELETE FROM lab.Customers  WHERE BatchID = 4;
DELETE FROM lab.Orders     WHERE BatchID = 4;
DELETE FROM lab.OrderItems WHERE BatchID = 4;
DELETE FROM lab.Payments   WHERE BatchID = 4;
DELETE FROM lab.Reviews    WHERE BatchID = 4;

IF NOT EXISTS (SELECT 1 FROM etl.Batch WHERE BatchID = 4)
    INSERT etl.Batch (BatchID, BatchName, PurchaseFrom, PurchaseTo, Description)
    VALUES (4, 'X1', NULL, NULL, N'Track B update test: late LAB order for December 2017');

INSERT lab.Customers (customer_id, customer_unique_id, customer_city, customer_state, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_CUST_X1', N'LAB_CUSTOMER_01', N'sao paulo', N'SP', 4, 4001, 'insert');

INSERT lab.Orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                   order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
                   BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_X1', N'LAB_CUST_X1', N'delivered', N'2017-12-10 10:00:00', N'2017-12-10 11:00:00',
        N'2017-12-11 10:00:00', N'2017-12-15 10:00:00', N'2017-12-16 10:00:00', 4, 4002, 'insert');

INSERT lab.OrderItems (order_id, order_item_id, product_id, seller_id, price, freight_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_X1', N'1', N'LAB_PRODUCT_01', N'LAB_SELLER_01', N'50.00', N'5.00', 4, 4003, 'insert');

INSERT lab.Payments (order_id, payment_sequential, payment_type, payment_installments, payment_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_X1', N'1', N'credit_card', N'1', N'55.00', 4, 4004, 'insert');

INSERT lab.Reviews (review_id, order_id, review_score, review_creation_date, review_answer_timestamp, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_REVIEW_X1', N'LAB_ORDER_X1', N'4', N'2017-12-16 10:00:00', N'2017-12-16 10:00:00', 4, 4005, 'insert');
GO
PRINT '=== BEFORE X1: LAB product-month rows ===';
SELECT p.ProductID, m.MonthStartDateKey, m.SalesAmount, m.FreightAmount, m.ItemCount, m.DistinctOrderCount
FROM dw.FactProductMonth m JOIN dw.DimProduct p ON p.ProductKey = m.ProductKey
WHERE m.IsTestData = 1 ORDER BY m.MonthStartDateKey, p.ProductID;
GO
EXEC etl.usp_RunBatch @BatchID = 4;
EXEC etl.usp_CheckBatch 4;
GO
PRINT '=== REPLAY X1 ===';
EXEC etl.usp_RunBatch @BatchID = 4;
EXEC etl.usp_RunBatch @BatchID = 4, @Force = 1;
EXEC etl.usp_CheckBatch 4;

SELECT l.RunID, d.TargetTable, d.RowsInserted, d.RowsUpdated
FROM etl.LoadLog l JOIN etl.LoadLogDetail d ON d.RunID = l.RunID
WHERE l.BatchID = 4 AND l.IsForced = 1 ORDER BY l.RunID, d.TargetTable;
GO
PRINT '=== AFTER X1: LAB product-month rows ===';
SELECT p.ProductID, m.MonthStartDateKey, m.SalesAmount, m.FreightAmount, m.ItemCount, m.DistinctOrderCount
FROM dw.FactProductMonth m JOIN dw.DimProduct p ON p.ProductKey = m.ProductKey
WHERE m.IsTestData = 1 ORDER BY m.MonthStartDateKey, p.ProductID;

-- Expected versus actual for December 2017.
SELECT CheckName, Expected, Actual, IIF(Expected = Actual, 'PASS', 'FAIL') AS Result
FROM (
    SELECT v.CheckName, v.Expected, v.Actual
    FROM (SELECT COUNT(*) AS RowsFound, SUM(SalesAmount) AS Sales, SUM(FreightAmount) AS Freight,
                 SUM(ItemCount) AS Items, SUM(DistinctOrderCount) AS Orders
          FROM dw.FactProductMonth WHERE IsTestData = 1 AND MonthStartDateKey = 20171201) a
    CROSS APPLY (VALUES
     ('Dec 2017 rows',    CAST(1  AS DECIMAL(18,2)), CAST(a.RowsFound AS DECIMAL(18,2))),
     ('Dec 2017 sales',   CAST(50 AS DECIMAL(18,2)), CAST(a.Sales     AS DECIMAL(18,2))),
     ('Dec 2017 freight', CAST(5  AS DECIMAL(18,2)), CAST(a.Freight   AS DECIMAL(18,2))),
     ('Dec 2017 items',   CAST(1  AS DECIMAL(18,2)), CAST(a.Items     AS DECIMAL(18,2))),
     ('Dec 2017 orders',  CAST(1  AS DECIMAL(18,2)), CAST(a.Orders    AS DECIMAL(18,2)))
    ) v (CheckName, Expected, Actual)) x;

IF NOT EXISTS (SELECT 1 FROM dw.FactProductMonth
               WHERE IsTestData = 1 AND MonthStartDateKey = 20171201
                 AND SalesAmount = 50 AND FreightAmount = 5 AND ItemCount = 1 AND DistinctOrderCount = 1)
    THROW 50103, 'X1 test failed.', 1;

PRINT '=== Reporting views, LAB rows only (test evidence) ===';
SELECT * FROM mart.vwCategoryMonth  WHERE IsTestData = 1 ORDER BY MonthStartDate;
SELECT * FROM mart.vwProductRanking WHERE IsTestData = 1 ORDER BY MonthStartDate, SalesRank;
SELECT BatchID, TableName, SourceKey, Operation, ChangeSeq, EffectiveAt
FROM etl.vwBatchManifest WHERE BatchID = 4 AND IsTestData = 1 ORDER BY TableName, SourceKey;
GO
