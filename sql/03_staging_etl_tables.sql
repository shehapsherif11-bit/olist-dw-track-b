/* Creates the load-control tables (etl), the LAB test source tables (lab)
   and the staging tables (stg).

   lab.* has the same columns as src.* plus the change information.
   stg.* has the same columns as src.* plus the batch information.

   ChangeSeq rule:  explicit LAB change in batch N = N*1000 + n   (n = 1, 2, 3, ...)
                    copy of a record in batch N    = N*1000
   So (source key, ChangeSeq) is unique, and ChangeSeq < N*1000 means "an earlier batch".
   DupNo numbers repeated rows with the same source key, so duplicates can be kept and rejected. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
/* ---------- load control ---------- */
CREATE TABLE etl.Batch (
    BatchID      INT           NOT NULL CONSTRAINT PK_Batch PRIMARY KEY,
    BatchName    VARCHAR(10)   NOT NULL CONSTRAINT UQ_Batch_Name UNIQUE,
    PurchaseFrom DATE          NULL,        -- inclusive. NULL = no real Olist orders
    PurchaseTo   DATE          NULL,        -- exclusive
    Description  NVARCHAR(200) NOT NULL);

CREATE TABLE etl.LoadState (               -- one row: the last successfully processed batch
    StateID               TINYINT      NOT NULL CONSTRAINT PK_LoadState PRIMARY KEY
                                       CONSTRAINT CK_LoadState_OneRow CHECK (StateID = 1),
    LastSuccessfulBatchID INT          NOT NULL,
    UpdatedAt             DATETIME2(3) NOT NULL);
INSERT etl.LoadState VALUES (1, 0, SYSDATETIME());

CREATE TABLE etl.LoadLog (                 -- one row per attempt
    RunID        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoadLog PRIMARY KEY,
    BatchID      INT            NOT NULL,
    IsForced     BIT            NOT NULL,
    StartTime    DATETIME2(3)   NOT NULL,
    EndTime      DATETIME2(3)   NULL,
    Status       VARCHAR(10)    NOT NULL CONSTRAINT CK_LoadLog_Status
                                CHECK (Status IN ('Running', 'Success', 'Failed', 'Skipped')),
    RowsStaged   INT            NULL,
    RowsInserted INT            NULL,
    RowsUpdated  INT            NULL,
    RowsRejected INT            NULL,
    ErrorText    NVARCHAR(4000) NULL);

CREATE TABLE etl.LoadLogDetail (           -- counts per target table
    RunID        INT           NOT NULL,
    TargetTable  NVARCHAR(128) NOT NULL,
    RowsInserted INT           NOT NULL,
    RowsUpdated  INT           NOT NULL,
    RowsRejected INT           NOT NULL,
    CONSTRAINT PK_LoadLogDetail PRIMARY KEY (RunID, TargetTable));

CREATE TABLE etl.DataIssue (               -- rejected rows, ignored changes and warnings
    IssueID   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DataIssue PRIMARY KEY,
    RunID     INT           NOT NULL,
    BatchID   INT           NOT NULL,
    TableName NVARCHAR(128) NOT NULL,
    SourceKey NVARCHAR(200) NULL,
    IssueType VARCHAR(20)   NOT NULL CONSTRAINT CK_DataIssue_Type
                            CHECK (IssueType IN ('REJECT', 'DUPLICATE', 'SCD0_IGNORED', 'WARNING')),
    Reason    NVARCHAR(400) NOT NULL,
    RowData   NVARCHAR(MAX) NULL,
    LoggedAt  DATETIME2(3)  NOT NULL CONSTRAINT DF_DataIssue_LoggedAt DEFAULT SYSDATETIME());
GO
/* ---------- LAB test source: ordered change records ---------- */
CREATE TABLE lab.Customers (
    customer_id NVARCHAR(64) NOT NULL, customer_unique_id NVARCHAR(64), customer_zip_code_prefix NVARCHAR(10),
    customer_city NVARCHAR(100), customer_state NVARCHAR(10),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (customer_id, ChangeSeq));

CREATE TABLE lab.Orders (
    order_id NVARCHAR(64) NOT NULL, customer_id NVARCHAR(64), order_status NVARCHAR(20),
    order_purchase_timestamp NVARCHAR(30), order_approved_at NVARCHAR(30),
    order_delivered_carrier_date NVARCHAR(30), order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (order_id, ChangeSeq));

CREATE TABLE lab.OrderItems (
    order_id NVARCHAR(64) NOT NULL, order_item_id NVARCHAR(10) NOT NULL, product_id NVARCHAR(64),
    seller_id NVARCHAR(64), shipping_limit_date NVARCHAR(30), price NVARCHAR(30), freight_value NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (order_id, order_item_id, ChangeSeq));

CREATE TABLE lab.Products (
    product_id NVARCHAR(64) NOT NULL, product_category_name NVARCHAR(100), product_name_lenght NVARCHAR(10),
    product_description_lenght NVARCHAR(10), product_photos_qty NVARCHAR(10), product_weight_g NVARCHAR(10),
    product_length_cm NVARCHAR(10), product_height_cm NVARCHAR(10), product_width_cm NVARCHAR(10),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (product_id, ChangeSeq));

CREATE TABLE lab.Sellers (
    seller_id NVARCHAR(64) NOT NULL, seller_zip_code_prefix NVARCHAR(10), seller_city NVARCHAR(100),
    seller_state NVARCHAR(10),
    original_seller_state NVARCHAR(10),      -- extra technical column, used to test SCD Type 0
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (seller_id, ChangeSeq));

CREATE TABLE lab.CategoryTranslation (
    product_category_name NVARCHAR(100) NOT NULL, product_category_name_english NVARCHAR(100),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (product_category_name, ChangeSeq));

CREATE TABLE lab.Payments (
    order_id NVARCHAR(64) NOT NULL, payment_sequential NVARCHAR(10) NOT NULL, payment_type NVARCHAR(30),
    payment_installments NVARCHAR(10), payment_value NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (order_id, payment_sequential, ChangeSeq));

CREATE TABLE lab.Reviews (
    review_id NVARCHAR(64) NOT NULL, order_id NVARCHAR(64) NOT NULL, review_score NVARCHAR(10),
    review_comment_title NVARCHAR(200), review_comment_message NVARCHAR(1000),
    review_creation_date NVARCHAR(30), review_answer_timestamp NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, Operation VARCHAR(10) NOT NULL, EffectiveAt DATETIME2(0) NULL,
    PRIMARY KEY (review_id, order_id, ChangeSeq));
GO
/* ---------- staging ---------- */
CREATE TABLE stg.Customers (
    customer_id NVARCHAR(64), customer_unique_id NVARCHAR(64), customer_zip_code_prefix NVARCHAR(10),
    customer_city NVARCHAR(100), customer_state NVARCHAR(10),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Customers UNIQUE (customer_id, ChangeSeq, DupNo));

CREATE TABLE stg.Orders (
    order_id NVARCHAR(64), customer_id NVARCHAR(64), order_status NVARCHAR(20),
    order_purchase_timestamp NVARCHAR(30), order_approved_at NVARCHAR(30),
    order_delivered_carrier_date NVARCHAR(30), order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Orders UNIQUE (order_id, ChangeSeq, DupNo));

CREATE TABLE stg.OrderItems (
    order_id NVARCHAR(64), order_item_id NVARCHAR(10), product_id NVARCHAR(64), seller_id NVARCHAR(64),
    shipping_limit_date NVARCHAR(30), price NVARCHAR(30), freight_value NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_OrderItems UNIQUE (order_id, order_item_id, ChangeSeq, DupNo));

CREATE TABLE stg.Products (
    product_id NVARCHAR(64), product_category_name NVARCHAR(100), product_name_lenght NVARCHAR(10),
    product_description_lenght NVARCHAR(10), product_photos_qty NVARCHAR(10), product_weight_g NVARCHAR(10),
    product_length_cm NVARCHAR(10), product_height_cm NVARCHAR(10), product_width_cm NVARCHAR(10),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Products UNIQUE (product_id, ChangeSeq, DupNo));

CREATE TABLE stg.Sellers (
    seller_id NVARCHAR(64), seller_zip_code_prefix NVARCHAR(10), seller_city NVARCHAR(100),
    seller_state NVARCHAR(10), original_seller_state NVARCHAR(10),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Sellers UNIQUE (seller_id, ChangeSeq, DupNo));

CREATE TABLE stg.CategoryTranslation (
    product_category_name NVARCHAR(100), product_category_name_english NVARCHAR(100),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_CategoryTranslation UNIQUE (product_category_name, ChangeSeq, DupNo));

CREATE TABLE stg.Payments (
    order_id NVARCHAR(64), payment_sequential NVARCHAR(10), payment_type NVARCHAR(30),
    payment_installments NVARCHAR(10), payment_value NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Payments UNIQUE (order_id, payment_sequential, ChangeSeq, DupNo));

CREATE TABLE stg.Reviews (
    review_id NVARCHAR(64), order_id NVARCHAR(64), review_score NVARCHAR(10),
    review_comment_title NVARCHAR(200), review_comment_message NVARCHAR(1000),
    review_creation_date NVARCHAR(30), review_answer_timestamp NVARCHAR(30),
    BatchID INT NOT NULL, ChangeSeq INT NOT NULL, DupNo INT NOT NULL, Operation VARCHAR(10) NOT NULL,
    IsTestData BIT NOT NULL, EffectiveAt DATETIME2(0) NULL, RejectReason NVARCHAR(400) NULL,
    ReceivedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_stg_Reviews UNIQUE (review_id, order_id, ChangeSeq, DupNo));
GO
-- Each batch is read by BatchID.
CREATE CLUSTERED INDEX CIX_stg_Customers           ON stg.Customers (BatchID, customer_id);
CREATE CLUSTERED INDEX CIX_stg_Orders              ON stg.Orders (BatchID, order_id);
CREATE CLUSTERED INDEX CIX_stg_OrderItems          ON stg.OrderItems (BatchID, order_id);
CREATE CLUSTERED INDEX CIX_stg_Products            ON stg.Products (BatchID, product_id);
CREATE CLUSTERED INDEX CIX_stg_Sellers             ON stg.Sellers (BatchID, seller_id);
CREATE CLUSTERED INDEX CIX_stg_CategoryTranslation ON stg.CategoryTranslation (BatchID, product_category_name);
CREATE CLUSTERED INDEX CIX_stg_Payments            ON stg.Payments (BatchID, order_id);
CREATE CLUSTERED INDEX CIX_stg_Reviews             ON stg.Reviews (BatchID, order_id);
GO
/* Batch manifest: every record received, with its operation and change sequence. */
CREATE VIEW etl.vwBatchManifest AS
SELECT BatchID, 'Customers' AS TableName, CONCAT(customer_id, '') AS SourceKey, Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Customers
UNION ALL SELECT BatchID, 'Orders', CONCAT(order_id, ''), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Orders
UNION ALL SELECT BatchID, 'OrderItems', CONCAT(order_id, ':', order_item_id), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.OrderItems
UNION ALL SELECT BatchID, 'Products', CONCAT(product_id, ''), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Products
UNION ALL SELECT BatchID, 'Sellers', CONCAT(seller_id, ''), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Sellers
UNION ALL SELECT BatchID, 'CategoryTranslation', CONCAT(product_category_name, ''), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.CategoryTranslation
UNION ALL SELECT BatchID, 'Payments', CONCAT(order_id, ':', payment_sequential), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Payments
UNION ALL SELECT BatchID, 'Reviews', CONCAT(review_id, ':', order_id), Operation, ChangeSeq, EffectiveAt, IsTestData FROM stg.Reviews;
GO
