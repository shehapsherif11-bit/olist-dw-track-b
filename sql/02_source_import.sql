/* SOURCE IMPORT: loads the 8 required CSV files into src without changing any value.
   All columns are text. Type conversion happens later, in the staging views.
   Change @DataPath below if your CSV files are in another folder.                  */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
DROP TABLE IF EXISTS src.Customers, src.Orders, src.OrderItems, src.Products,
                     src.Sellers, src.CategoryTranslation, src.Payments, src.Reviews;
GO
-- Column order and names are the same as in the CSV files.
CREATE TABLE src.Customers (
    customer_id NVARCHAR(64), customer_unique_id NVARCHAR(64), customer_zip_code_prefix NVARCHAR(10),
    customer_city NVARCHAR(100), customer_state NVARCHAR(10));
CREATE TABLE src.Orders (
    order_id NVARCHAR(64), customer_id NVARCHAR(64), order_status NVARCHAR(20),
    order_purchase_timestamp NVARCHAR(30), order_approved_at NVARCHAR(30),
    order_delivered_carrier_date NVARCHAR(30), order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30));
CREATE TABLE src.OrderItems (
    order_id NVARCHAR(64), order_item_id NVARCHAR(10), product_id NVARCHAR(64), seller_id NVARCHAR(64),
    shipping_limit_date NVARCHAR(30), price NVARCHAR(30), freight_value NVARCHAR(30));
CREATE TABLE src.Products (
    product_id NVARCHAR(64), product_category_name NVARCHAR(100), product_name_lenght NVARCHAR(10),
    product_description_lenght NVARCHAR(10), product_photos_qty NVARCHAR(10), product_weight_g NVARCHAR(10),
    product_length_cm NVARCHAR(10), product_height_cm NVARCHAR(10), product_width_cm NVARCHAR(10));
CREATE TABLE src.Sellers (
    seller_id NVARCHAR(64), seller_zip_code_prefix NVARCHAR(10), seller_city NVARCHAR(100), seller_state NVARCHAR(10));
CREATE TABLE src.CategoryTranslation (
    product_category_name NVARCHAR(100), product_category_name_english NVARCHAR(100));
CREATE TABLE src.Payments (
    order_id NVARCHAR(64), payment_sequential NVARCHAR(10), payment_type NVARCHAR(30),
    payment_installments NVARCHAR(10), payment_value NVARCHAR(30));
CREATE TABLE src.Reviews (
    review_id NVARCHAR(64), order_id NVARCHAR(64), review_score NVARCHAR(10),
    review_comment_title NVARCHAR(200), review_comment_message NVARCHAR(1000),
    review_creation_date NVARCHAR(30), review_answer_timestamp NVARCHAR(30));
GO
DECLARE @DataPath NVARCHAR(260) = N'C:\Users\original\Desktop\DW\Data\';

-- Two files use Windows line endings (0x0d0a). The others use 0x0a.
DECLARE @Files TABLE (Id INT IDENTITY(1,1), TableName SYSNAME, FileName NVARCHAR(100), RowEnd NVARCHAR(10));
INSERT @Files (TableName, FileName, RowEnd) VALUES
 (N'src.Customers',           N'olist_customers_dataset.csv',           N'0x0a'),
 (N'src.Orders',              N'olist_orders_dataset.csv',              N'0x0a'),
 (N'src.OrderItems',          N'olist_order_items_dataset.csv',         N'0x0a'),
 (N'src.Products',            N'olist_products_dataset.csv',            N'0x0a'),
 (N'src.Sellers',             N'olist_sellers_dataset.csv',             N'0x0a'),
 (N'src.CategoryTranslation', N'product_category_name_translation.csv', N'0x0d0a'),
 (N'src.Payments',            N'olist_order_payments_dataset.csv',      N'0x0a'),
 (N'src.Reviews',             N'olist_order_reviews_dataset.csv',       N'0x0d0a');

-- BULK INSERT does not accept a variable for the file path, so the command is built as text.
DECLARE @Id INT = 1, @Sql NVARCHAR(MAX);
WHILE @Id <= (SELECT MAX(Id) FROM @Files)
BEGIN
    SELECT @Sql = N'BULK INSERT ' + TableName + N' FROM ''' + @DataPath + FileName + N'''
        WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', FIELDTERMINATOR = '','',
              ROWTERMINATOR = ''' + RowEnd + N''', CODEPAGE = ''65001'', TABLOCK);'
    FROM @Files WHERE Id = @Id;
    EXEC (@Sql);
    SET @Id += 1;
END;
GO
-- Check: row counts must equal the number of data records in each file.
SELECT x.TableName, x.ExpectedRows, x.ActualRows,
       IIF(x.ExpectedRows = x.ActualRows, 'PASS', 'FAIL') AS Result
FROM (VALUES
 ('src.Customers',            99441, (SELECT COUNT(*) FROM src.Customers)),
 ('src.Orders',               99441, (SELECT COUNT(*) FROM src.Orders)),
 ('src.OrderItems',          112650, (SELECT COUNT(*) FROM src.OrderItems)),
 ('src.Products',             32951, (SELECT COUNT(*) FROM src.Products)),
 ('src.Sellers',               3095, (SELECT COUNT(*) FROM src.Sellers)),
 ('src.CategoryTranslation',     71, (SELECT COUNT(*) FROM src.CategoryTranslation)),
 ('src.Payments',            103886, (SELECT COUNT(*) FROM src.Payments)),
 ('src.Reviews',              99224, (SELECT COUNT(*) FROM src.Reviews))
) AS x(TableName, ExpectedRows, ActualRows);

IF (SELECT COUNT(*) FROM src.Customers) <> 99441 OR (SELECT COUNT(*) FROM src.Orders) <> 99441
   OR (SELECT COUNT(*) FROM src.OrderItems) <> 112650 OR (SELECT COUNT(*) FROM src.Products) <> 32951
   OR (SELECT COUNT(*) FROM src.Sellers) <> 3095 OR (SELECT COUNT(*) FROM src.CategoryTranslation) <> 71
   OR (SELECT COUNT(*) FROM src.Payments) <> 103886 OR (SELECT COUNT(*) FROM src.Reviews) <> 99224
    THROW 50001, 'Source import row counts do not match the CSV files.', 1;
GO
