/* ETL steps 1 and 2: EXTRACT one batch into staging, then VALIDATE it.
   Also creates the typed staging views (type conversion and text normalization). */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- Trims a city name, makes it lower case and joins repeated spaces. Wrong values are not guessed.
CREATE OR ALTER FUNCTION etl.fnCleanCity (@City NVARCHAR(100))
RETURNS NVARCHAR(100)
AS
BEGIN
    RETURN NULLIF(LOWER(TRIM(REPLACE(REPLACE(REPLACE(@City, N' ', N'<>'), N'><', N''), N'<>', N' '))), N'');
END;
GO
/* ---------- typed views: only accepted rows (RejectReason IS NULL) ---------- */
CREATE OR ALTER VIEW stg.vwOrders AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), order_id)    AS OrderID,
       CONVERT(VARCHAR(64), customer_id) AS CustomerID,
       LOWER(TRIM(order_status))         AS OrderStatus,
       TRY_CONVERT(DATETIME2(0), order_purchase_timestamp)      AS PurchaseTimestamp,
       TRY_CONVERT(DATETIME2(0), order_approved_at)             AS ApprovedAt,
       TRY_CONVERT(DATETIME2(0), order_delivered_carrier_date)  AS CarrierAt,
       TRY_CONVERT(DATETIME2(0), order_delivered_customer_date) AS DeliveredAt,
       TRY_CONVERT(DATETIME2(0), order_estimated_delivery_date) AS EstimatedAt
FROM stg.Orders
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwCustomers AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), customer_id)        AS CustomerID,
       CONVERT(VARCHAR(64), customer_unique_id) AS BusinessCustomerID,
       etl.fnCleanCity(customer_city)           AS City,
       CONVERT(VARCHAR(10), NULLIF(UPPER(TRIM(customer_state)), N'')) AS State
FROM stg.Customers
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwOrderItems AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), order_id)   AS OrderID,
       TRY_CONVERT(INT, order_item_id)  AS OrderItemID,
       CONVERT(VARCHAR(64), product_id) AS ProductID,
       CONVERT(VARCHAR(64), seller_id)  AS SellerID,
       TRY_CONVERT(DECIMAL(18,2), price)         AS ItemSalesAmount,
       TRY_CONVERT(DECIMAL(18,2), freight_value) AS FreightAmount
FROM stg.OrderItems
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwProducts AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), product_id)         AS ProductID,
       NULLIF(TRIM(product_category_name), N'') AS CategoryCode,
       TRY_CONVERT(INT, product_weight_g)       AS WeightG,
       TRY_CONVERT(INT, product_length_cm)      AS LengthCm,
       TRY_CONVERT(INT, product_height_cm)      AS HeightCm,
       TRY_CONVERT(INT, product_width_cm)       AS WidthCm
FROM stg.Products
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwSellers AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), seller_id) AS SellerID,
       etl.fnCleanCity(seller_city)    AS City,
       CONVERT(VARCHAR(10), NULLIF(UPPER(TRIM(seller_state)), N''))         AS State,
       CONVERT(VARCHAR(10), NULLIF(UPPER(TRIM(original_seller_state)), N'')) AS OriginalSellerState,
       EffectiveAt,
       CAST(IIF(ChangeSeq % 1000 = 0, 0, 1) AS BIT) AS IsExplicitChange
FROM stg.Sellers
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwCategories AS
SELECT BatchID, IsTestData,
       TRIM(product_category_name)         AS CategoryCode,
       TRIM(product_category_name_english) AS CategoryLabelEN
FROM stg.CategoryTranslation
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwPayments AS
SELECT BatchID, IsTestData, ChangeSeq,
       CONVERT(VARCHAR(64), order_id)        AS OrderID,
       TRY_CONVERT(INT, payment_sequential)  AS PaymentSequential,
       TRIM(payment_type)                    AS PaymentType,
       TRY_CONVERT(INT, payment_installments) AS Installments,
       TRY_CONVERT(DECIMAL(18,2), payment_value) AS PaymentValue
FROM stg.Payments
WHERE RejectReason IS NULL;
GO
CREATE OR ALTER VIEW stg.vwReviews AS
SELECT BatchID, IsTestData,
       CONVERT(VARCHAR(64), review_id) AS ReviewID,
       CONVERT(VARCHAR(64), order_id)  AS OrderID,
       TRY_CONVERT(INT, review_score)  AS ReviewScore,
       TRY_CONVERT(DATETIME2(0), review_creation_date)    AS CreatedAt,
       TRY_CONVERT(DATETIME2(0), review_answer_timestamp) AS AnsweredAt
FROM stg.Reviews
WHERE RejectReason IS NULL;
GO
/* =====================================================================================
   EXTRACT: copies only the records of one batch into staging.
   - Real orders: purchase date inside the batch range.
   - LAB orders: any LAB order with a change record in this batch.
   - Related records (items, customer, product, seller, category, payments, reviews)
     are copied with their latest state up to this batch.
   - LAB dimension changes in this batch are copied even without a new sale.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_ExtractBatch @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @From DATE, @To DATE, @CopySeq INT = @BatchID * 1000;
    SELECT @From = PurchaseFrom, @To = PurchaseTo FROM etl.Batch WHERE BatchID = @BatchID;

    -- A retry starts clean.
    DELETE FROM stg.Orders              WHERE BatchID = @BatchID;
    DELETE FROM stg.OrderItems          WHERE BatchID = @BatchID;
    DELETE FROM stg.Customers           WHERE BatchID = @BatchID;
    DELETE FROM stg.Products            WHERE BatchID = @BatchID;
    DELETE FROM stg.Sellers             WHERE BatchID = @BatchID;
    DELETE FROM stg.CategoryTranslation WHERE BatchID = @BatchID;
    DELETE FROM stg.Payments            WHERE BatchID = @BatchID;
    DELETE FROM stg.Reviews             WHERE BatchID = @BatchID;

    -- Source rows with an unreadable purchase date can never match a date range: report them once.
    IF @BatchID = 1
        INSERT etl.DataIssue (RunID, BatchID, TableName, SourceKey, IssueType, Reason)
        SELECT @RunID, @BatchID, N'src.Orders', order_id, 'REJECT', N'Unreadable purchase timestamp'
        FROM src.Orders WHERE TRY_CONVERT(DATETIME2(0), order_purchase_timestamp) IS NULL;

    /* 1. Orders touched by this batch */
    CREATE TABLE #RealOrders (order_id NVARCHAR(64) NOT NULL);
    INSERT #RealOrders
    SELECT DISTINCT order_id FROM src.Orders
    WHERE TRY_CONVERT(DATETIME2(0), order_purchase_timestamp) >= @From
      AND TRY_CONVERT(DATETIME2(0), order_purchase_timestamp) <  @To;

    CREATE TABLE #LabOrders (order_id NVARCHAR(64) NOT NULL);
    INSERT #LabOrders
    SELECT order_id FROM lab.Orders     WHERE BatchID = @BatchID
    UNION SELECT order_id FROM lab.OrderItems WHERE BatchID = @BatchID
    UNION SELECT order_id FROM lab.Payments   WHERE BatchID = @BatchID
    UNION SELECT order_id FROM lab.Reviews    WHERE BatchID = @BatchID;

    /* 2. Orders */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Orders WHERE BatchID <= @BatchID),
    Incoming AS (
        SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
               order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Orders WHERE order_id IN (SELECT order_id FROM #RealOrders)
        UNION ALL
        SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
               order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND order_id IN (SELECT order_id FROM #LabOrders))
    INSERT stg.Orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
                       BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.order_id, i.customer_id, i.order_status, i.order_purchase_timestamp, i.order_approved_at,
           i.order_delivered_carrier_date, i.order_delivered_customer_date, i.order_estimated_delivery_date,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.order_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Orders p WHERE p.order_id = i.order_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 3. Order items. In B1 also copy items that have no parent order, so they can be rejected. */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id, order_item_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.OrderItems WHERE BatchID <= @BatchID),
    Incoming AS (
        SELECT s.order_id, s.order_item_id, s.product_id, s.seller_id, s.shipping_limit_date, s.price, s.freight_value,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.OrderItems s
        WHERE s.order_id IN (SELECT order_id FROM #RealOrders)
           OR (@BatchID = 1 AND NOT EXISTS (SELECT 1 FROM src.Orders o WHERE o.order_id = s.order_id))
        UNION ALL
        SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND order_id IN (SELECT order_id FROM #LabOrders))
    INSERT stg.OrderItems (order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value,
                           BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id, i.shipping_limit_date, i.price, i.freight_value,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.order_id, i.order_item_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.OrderItems p WHERE p.order_id = i.order_id
                       AND p.order_item_id = i.order_item_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 4. Customers of the staged orders */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Customers WHERE BatchID <= @BatchID),
    Needed AS (SELECT customer_id FROM stg.Orders WHERE BatchID = @BatchID),
    Incoming AS (
        SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Customers WHERE customer_id IN (SELECT customer_id FROM Needed)
        UNION ALL
        SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND (BatchID = @BatchID OR customer_id IN (SELECT customer_id FROM Needed)))
    INSERT stg.Customers (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state,
                          BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.customer_id, i.customer_unique_id, i.customer_zip_code_prefix, i.customer_city, i.customer_state,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.customer_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Customers p WHERE p.customer_id = i.customer_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 5. Payments of the touched orders */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id, payment_sequential ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Payments WHERE BatchID <= @BatchID),
    Incoming AS (
        SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Payments WHERE order_id IN (SELECT order_id FROM #RealOrders)
        UNION ALL
        SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND order_id IN (SELECT order_id FROM #LabOrders))
    INSERT stg.Payments (order_id, payment_sequential, payment_type, payment_installments, payment_value,
                         BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.order_id, i.payment_sequential, i.payment_type, i.payment_installments, i.payment_value,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.order_id, i.payment_sequential ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Payments p WHERE p.order_id = i.order_id
                       AND p.payment_sequential = i.payment_sequential AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 6. Reviews of the touched orders */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY review_id, order_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Reviews WHERE BatchID <= @BatchID),
    Incoming AS (
        SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
               review_creation_date, review_answer_timestamp,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Reviews WHERE order_id IN (SELECT order_id FROM #RealOrders)
        UNION ALL
        SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
               review_creation_date, review_answer_timestamp,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND order_id IN (SELECT order_id FROM #LabOrders))
    INSERT stg.Reviews (review_id, order_id, review_score, review_comment_title, review_comment_message,
                        review_creation_date, review_answer_timestamp,
                        BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.review_id, i.order_id, i.review_score, i.review_comment_title, i.review_comment_message,
           i.review_creation_date, i.review_answer_timestamp,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.review_id, i.order_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Reviews p WHERE p.review_id = i.review_id
                       AND p.order_id = i.order_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 7. Products of the staged items + LAB product changes of this batch */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Products WHERE BatchID <= @BatchID),
    Needed AS (SELECT product_id FROM stg.OrderItems WHERE BatchID = @BatchID),
    Incoming AS (
        SELECT product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty,
               product_weight_g, product_length_cm, product_height_cm, product_width_cm,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Products WHERE product_id IN (SELECT product_id FROM Needed)
        UNION ALL
        SELECT product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty,
               product_weight_g, product_length_cm, product_height_cm, product_width_cm,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND (BatchID = @BatchID OR product_id IN (SELECT product_id FROM Needed)))
    INSERT stg.Products (product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty,
                         product_weight_g, product_length_cm, product_height_cm, product_width_cm,
                         BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.product_id, i.product_category_name, i.product_name_lenght, i.product_description_lenght, i.product_photos_qty,
           i.product_weight_g, i.product_length_cm, i.product_height_cm, i.product_width_cm,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.product_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Products p WHERE p.product_id = i.product_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 8. Sellers of the staged items + LAB seller changes of this batch.
          LAB uses the latest state up to this batch, so an old row never replaces a relocation. */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY ChangeSeq DESC) AS rn
        FROM lab.Sellers WHERE BatchID <= @BatchID),
    Needed AS (SELECT seller_id FROM stg.OrderItems WHERE BatchID = @BatchID),
    Incoming AS (
        SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state,
               CAST(NULL AS NVARCHAR(10)) AS original_seller_state,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.Sellers WHERE seller_id IN (SELECT seller_id FROM Needed)
        UNION ALL
        SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state, original_seller_state,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND (BatchID = @BatchID OR seller_id IN (SELECT seller_id FROM Needed)))
    INSERT stg.Sellers (seller_id, seller_zip_code_prefix, seller_city, seller_state, original_seller_state,
                        BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.seller_id, i.seller_zip_code_prefix, i.seller_city, i.seller_state, i.original_seller_state,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.seller_id ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.Sellers p WHERE p.seller_id = i.seller_id AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;

    /* 9. Category labels of the staged products + LAB category changes of this batch */
    WITH LabLatest AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY product_category_name ORDER BY ChangeSeq DESC) AS rn
        FROM lab.CategoryTranslation WHERE BatchID <= @BatchID),
    Needed AS (SELECT product_category_name FROM stg.Products WHERE BatchID = @BatchID),
    Incoming AS (
        SELECT product_category_name, product_category_name_english,
               @CopySeq AS ChangeSeq, 0 AS IsTestData, CAST(NULL AS DATETIME2(0)) AS EffectiveAt
        FROM src.CategoryTranslation WHERE product_category_name IN (SELECT product_category_name FROM Needed)
        UNION ALL
        SELECT product_category_name, product_category_name_english,
               IIF(BatchID = @BatchID, ChangeSeq, @CopySeq), 1, EffectiveAt
        FROM LabLatest WHERE rn = 1 AND (BatchID = @BatchID OR product_category_name IN (SELECT product_category_name FROM Needed)))
    INSERT stg.CategoryTranslation (product_category_name, product_category_name_english,
                                    BatchID, ChangeSeq, DupNo, Operation, IsTestData, EffectiveAt)
    SELECT i.product_category_name, i.product_category_name_english,
           @BatchID, i.ChangeSeq,
           ROW_NUMBER() OVER (PARTITION BY i.product_category_name ORDER BY (SELECT NULL)),
           IIF(EXISTS (SELECT 1 FROM stg.CategoryTranslation p WHERE p.product_category_name = i.product_category_name
                       AND p.ChangeSeq < @CopySeq), 'update', 'insert'),
           i.IsTestData, i.EffectiveAt
    FROM Incoming i;
END;
GO
/* =====================================================================================
   VALIDATE: marks bad rows with a reason. No row is deleted.
   Duplicate rule: exact copies -> keep the first row, mark the others.
                   different values for the same key -> reject all of them for review.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_ValidateBatch @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exact NVARCHAR(100) = N'Exact duplicate: first copy kept',
            @Conflict NVARCHAR(100) = N'Conflicting duplicate key: needs a decision';

    UPDATE stg.Orders              SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.OrderItems          SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.Customers           SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.Products            SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.Sellers             SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.CategoryTranslation SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.Payments            SET RejectReason = NULL WHERE BatchID = @BatchID;
    UPDATE stg.Reviews             SET RejectReason = NULL WHERE BatchID = @BatchID;

    /* ---- duplicate source keys ---- */
    WITH D AS (
        SELECT order_id, COUNT(DISTINCT CONCAT(customer_id, '|', order_status, '|', order_purchase_timestamp, '|',
               order_approved_at, '|', order_delivered_carrier_date, '|', order_delivered_customer_date, '|',
               order_estimated_delivery_date)) AS Versions
        FROM stg.Orders WHERE BatchID = @BatchID GROUP BY order_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Orders s JOIN D ON D.order_id = s.order_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT order_id, order_item_id, COUNT(DISTINCT CONCAT(product_id, '|', seller_id, '|', shipping_limit_date, '|',
               price, '|', freight_value)) AS Versions
        FROM stg.OrderItems WHERE BatchID = @BatchID GROUP BY order_id, order_item_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.OrderItems s JOIN D ON D.order_id = s.order_id AND D.order_item_id = s.order_item_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT customer_id, COUNT(DISTINCT CONCAT(customer_unique_id, '|', customer_zip_code_prefix, '|',
               customer_city, '|', customer_state)) AS Versions
        FROM stg.Customers WHERE BatchID = @BatchID GROUP BY customer_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Customers s JOIN D ON D.customer_id = s.customer_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT product_id, COUNT(DISTINCT CONCAT(product_category_name, '|', product_name_lenght, '|',
               product_description_lenght, '|', product_photos_qty, '|', product_weight_g, '|', product_length_cm, '|',
               product_height_cm, '|', product_width_cm)) AS Versions
        FROM stg.Products WHERE BatchID = @BatchID GROUP BY product_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Products s JOIN D ON D.product_id = s.product_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT seller_id, COUNT(DISTINCT CONCAT(seller_zip_code_prefix, '|', seller_city, '|', seller_state, '|',
               original_seller_state, '|', EffectiveAt)) AS Versions
        FROM stg.Sellers WHERE BatchID = @BatchID GROUP BY seller_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Sellers s JOIN D ON D.seller_id = s.seller_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT product_category_name, COUNT(DISTINCT product_category_name_english) AS Versions
        FROM stg.CategoryTranslation WHERE BatchID = @BatchID GROUP BY product_category_name HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions <= 1, @Exact, @Conflict)
    FROM stg.CategoryTranslation s JOIN D ON D.product_category_name = s.product_category_name
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT order_id, payment_sequential, COUNT(DISTINCT CONCAT(payment_type, '|', payment_installments, '|',
               payment_value)) AS Versions
        FROM stg.Payments WHERE BatchID = @BatchID GROUP BY order_id, payment_sequential HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Payments s JOIN D ON D.order_id = s.order_id AND D.payment_sequential = s.payment_sequential
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    WITH D AS (
        SELECT review_id, order_id, COUNT(DISTINCT CONCAT(review_score, '|', review_comment_title, '|',
               review_comment_message, '|', review_creation_date, '|', review_answer_timestamp)) AS Versions
        FROM stg.Reviews WHERE BatchID = @BatchID GROUP BY review_id, order_id HAVING COUNT(*) > 1)
    UPDATE s SET RejectReason = IIF(D.Versions = 1, @Exact, @Conflict)
    FROM stg.Reviews s JOIN D ON D.review_id = s.review_id AND D.order_id = s.order_id
    WHERE s.BatchID = @BatchID AND (D.Versions > 1 OR s.DupNo > 1);

    /* ---- required fields and data types ---- */
    UPDATE stg.Orders SET RejectReason = N'Missing key, status or purchase timestamp'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(order_id, N'') IS NULL OR NULLIF(customer_id, N'') IS NULL OR NULLIF(order_status, N'') IS NULL
           OR TRY_CONVERT(DATETIME2(0), order_purchase_timestamp) IS NULL);

    UPDATE stg.Customers SET RejectReason = N'Missing customer_id or customer_unique_id'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(customer_id, N'') IS NULL OR NULLIF(customer_unique_id, N'') IS NULL);

    UPDATE stg.OrderItems SET RejectReason = N'Missing key, or price/freight missing, not a number or negative'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(order_id, N'') IS NULL OR ISNULL(TRY_CONVERT(INT, order_item_id), 0) <= 0
           OR ISNULL(TRY_CONVERT(DECIMAL(18,2), price), -1) < 0
           OR ISNULL(TRY_CONVERT(DECIMAL(18,2), freight_value), -1) < 0);

    -- Items need an accepted parent order in the same batch. Orders were validated first.
    UPDATE i SET RejectReason = N'No identifiable parent order'
    FROM stg.OrderItems i
    WHERE i.BatchID = @BatchID AND i.RejectReason IS NULL
      AND NOT EXISTS (SELECT 1 FROM stg.Orders o
                      WHERE o.BatchID = @BatchID AND o.order_id = i.order_id AND o.RejectReason IS NULL);

    UPDATE stg.Products SET RejectReason = N'Missing product_id'
    WHERE BatchID = @BatchID AND RejectReason IS NULL AND NULLIF(product_id, N'') IS NULL;

    UPDATE stg.Sellers SET RejectReason = N'Missing seller_id'
    WHERE BatchID = @BatchID AND RejectReason IS NULL AND NULLIF(seller_id, N'') IS NULL;

    UPDATE stg.CategoryTranslation SET RejectReason = N'Missing category code or English label'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(TRIM(product_category_name), N'') IS NULL OR NULLIF(TRIM(product_category_name_english), N'') IS NULL);

    UPDATE stg.Payments SET RejectReason = N'Missing key, or payment value missing, not a number or negative'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(order_id, N'') IS NULL OR TRY_CONVERT(INT, payment_sequential) IS NULL
           OR ISNULL(TRY_CONVERT(DECIMAL(18,2), payment_value), -1) < 0);

    UPDATE stg.Reviews SET RejectReason = N'Missing key, or review score not between 1 and 5'
    WHERE BatchID = @BatchID AND RejectReason IS NULL
      AND (NULLIF(review_id, N'') IS NULL OR NULLIF(order_id, N'') IS NULL
           OR ISNULL(TRY_CONVERT(INT, review_score), 0) NOT BETWEEN 1 AND 5);

    /* ---- keep every rejected row, with its values, in the audit table ---- */
    INSERT etl.DataIssue (RunID, BatchID, TableName, SourceKey, IssueType, Reason, RowData)
    SELECT @RunID, @BatchID, N'stg.Orders', s.order_id, IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Orders s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.OrderItems', CONCAT(s.order_id, ':', s.order_item_id), IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.OrderItems s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.Customers', s.customer_id, IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Customers s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.Products', s.product_id, IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Products s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.Sellers', s.seller_id, IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Sellers s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.CategoryTranslation', s.product_category_name, IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.CategoryTranslation s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.Payments', CONCAT(s.order_id, ':', s.payment_sequential), IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Payments s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL
    UNION ALL
    SELECT @RunID, @BatchID, N'stg.Reviews', CONCAT(s.review_id, ':', s.order_id), IIF(s.RejectReason = @Exact, 'DUPLICATE', 'REJECT'),
           s.RejectReason, (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM stg.Reviews s WHERE s.BatchID = @BatchID AND s.RejectReason IS NOT NULL;

    /* ---- warning: a category code without an English translation keeps the code as its label ---- */
    INSERT etl.DataIssue (RunID, BatchID, TableName, SourceKey, IssueType, Reason)
    SELECT @RunID, @BatchID, N'stg.Products', p.CategoryCode, 'WARNING',
           CONCAT(N'No English translation; the code is used as the label. Products: ', COUNT(*))
    FROM stg.vwProducts p
    WHERE p.BatchID = @BatchID AND p.CategoryCode IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM stg.vwCategories c WHERE c.BatchID = @BatchID AND c.CategoryCode = p.CategoryCode)
    GROUP BY p.CategoryCode;
END;
GO
