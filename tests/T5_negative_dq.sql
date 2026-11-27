/* Negative data-quality test: bad rows go into staging as a fake batch 99.
   Validation must reject them. Everything is rolled back, so nothing stays in the database. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @Found TABLE (TableName NVARCHAR(128), SourceKey NVARCHAR(200), IssueType VARCHAR(20), Reason NVARCHAR(400));

BEGIN TRANSACTION;

INSERT stg.Orders (order_id, customer_id, order_status, order_purchase_timestamp,
                   BatchID, ChangeSeq, DupNo, Operation, IsTestData)
VALUES (N'BAD_ORDER', N'BAD_CUST', N'delivered', N'2017-01-10 10:00:00', 99, 99000, 1, 'insert', 1);

INSERT stg.OrderItems (order_id, order_item_id, price, freight_value, BatchID, ChangeSeq, DupNo, Operation, IsTestData)
VALUES (N'BAD_ORDER', N'1', NULL,   N'1.00', 99, 99000, 1, 'insert', 1),   -- missing amount
       (N'NO_PARENT', N'1', N'10',  N'1.00', 99, 99000, 1, 'insert', 1),   -- no parent order
       (N'BAD_ORDER', N'2', N'-5',  N'1.00', 99, 99000, 1, 'insert', 1);   -- negative amount

INSERT stg.Payments (order_id, payment_sequential, payment_value, BatchID, ChangeSeq, DupNo, Operation, IsTestData)
VALUES (N'BAD_ORDER', N'1', N'10', 99, 99000, 1, 'insert', 1),             -- conflicting duplicate
       (N'BAD_ORDER', N'1', N'20', 99, 99000, 2, 'insert', 1);

INSERT stg.Sellers (seller_id, seller_city, seller_state, BatchID, ChangeSeq, DupNo, Operation, IsTestData)
VALUES (N'BAD_SELLER', N'sao paulo', N'SP', 99, 99000, 1, 'insert', 1),    -- exact duplicate
       (N'BAD_SELLER', N'sao paulo', N'SP', 99, 99000, 2, 'insert', 1);

INSERT stg.Reviews (review_id, order_id, review_score, BatchID, ChangeSeq, DupNo, Operation, IsTestData)
VALUES (N'BAD_REVIEW', N'BAD_ORDER', N'7', 99, 99000, 1, 'insert', 1);     -- score out of range

EXEC etl.usp_ValidateBatch @BatchID = 99, @RunID = 0;

INSERT @Found SELECT TableName, SourceKey, IssueType, Reason FROM etl.DataIssue WHERE BatchID = 99;

ROLLBACK TRANSACTION;

SELECT * FROM @Found ORDER BY TableName, SourceKey;

SELECT CheckName, Expected, Actual, IIF(Expected = Actual, 'PASS', 'FAIL') AS Result
INTO #Check
FROM (VALUES
 ('Items rejected',                    3, (SELECT COUNT(*) FROM @Found WHERE TableName = N'stg.OrderItems' AND IssueType = 'REJECT')),
 ('Conflicting payments rejected',     2, (SELECT COUNT(*) FROM @Found WHERE TableName = N'stg.Payments' AND IssueType = 'REJECT')),
 ('Exact duplicate seller collapsed',  1, (SELECT COUNT(*) FROM @Found WHERE TableName = N'stg.Sellers' AND IssueType = 'DUPLICATE')),
 ('Invalid review rejected',           1, (SELECT COUNT(*) FROM @Found WHERE TableName = N'stg.Reviews' AND IssueType = 'REJECT')),
 ('Test rows left after rollback',     0, (SELECT COUNT(*) FROM etl.vwBatchManifest WHERE BatchID = 99))
) v (CheckName, Expected, Actual);

SELECT * FROM #Check;
IF EXISTS (SELECT 1 FROM #Check WHERE Result = 'FAIL')
    THROW 50107, 'Negative data-quality test failed.', 1;
GO
