/* Creates the Star Schema (dw), the track B table, the Snowflake alternative (sf),
   the unknown members (key 0) and the calendar.

   Unknown member (key 0): used when a descriptive value is missing but the fact is valid. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- required for the filtered index on DimSeller
SET ANSI_NULLS ON;
GO
CREATE TABLE dw.DimDate (
    DateKey        INT      NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,   -- YYYYMMDD, 0 = unknown
    DateValue      DATE     NULL,
    [Day]          TINYINT  NULL,
    [Month]        TINYINT  NULL,
    [Quarter]      TINYINT  NULL,
    [Year]         SMALLINT NULL,
    MonthStartDate DATE     NULL);

CREATE TABLE dw.DimProduct (
    ProductKey      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimProduct PRIMARY KEY,
    ProductID       VARCHAR(64)   NOT NULL CONSTRAINT UQ_DimProduct_ID UNIQUE,
    CategoryCode    NVARCHAR(100) NULL,
    CategoryLabelEN NVARCHAR(100) NOT NULL,    -- SCD Type 1
    WeightG         INT NULL,
    LengthCm        INT NULL,
    HeightCm        INT NULL,
    WidthCm         INT NULL,
    InsertedBatchID INT NOT NULL,
    LastBatchID     INT NOT NULL,
    LoadedAt        DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedAt       DATETIME2(3) NULL);

CREATE TABLE dw.DimCustomer (
    CustomerKey        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCustomer PRIMARY KEY,
    BusinessCustomerID VARCHAR(64) NOT NULL CONSTRAINT UQ_DimCustomer_ID UNIQUE,  -- customer_unique_id
    InsertedBatchID    INT NOT NULL,
    LoadedAt           DATETIME2(3) NOT NULL DEFAULT SYSDATETIME());

CREATE TABLE dw.DimDeliveryLocation (
    DeliveryLocationKey INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimDeliveryLocation PRIMARY KEY,
    City                NVARCHAR(100) NOT NULL,
    State               VARCHAR(10)   NOT NULL,
    InsertedBatchID     INT NOT NULL,
    LoadedAt            DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_DimDeliveryLocation UNIQUE (City, State));

-- One row per VERSION of a seller (SCD Type 2). OriginalSellerState is SCD Type 0.
CREATE TABLE dw.DimSeller (
    SellerKey           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimSeller PRIMARY KEY,
    SellerID            VARCHAR(64)   NOT NULL,
    City                NVARCHAR(100) NULL,
    State               VARCHAR(10)   NULL,
    OriginalSellerState VARCHAR(10)   NULL,
    ValidFrom           DATETIME2(0)  NOT NULL,   -- inclusive
    ValidTo             DATETIME2(0)  NOT NULL,   -- exclusive
    IsCurrent           BIT           NOT NULL,
    InsertedBatchID     INT NOT NULL,
    LastBatchID         INT NOT NULL,
    LoadedAt            DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedAt           DATETIME2(3) NULL,
    CONSTRAINT CK_DimSeller_Period  CHECK (ValidFrom < ValidTo),
    CONSTRAINT CK_DimSeller_Current CHECK ((IsCurrent = 1 AND ValidTo = '9999-12-31')
                                        OR (IsCurrent = 0 AND ValidTo < '9999-12-31')),
    CONSTRAINT UQ_DimSeller_Version UNIQUE (SellerID, ValidFrom));
-- Exactly one current row per seller.
CREATE UNIQUE INDEX UX_DimSeller_Current ON dw.DimSeller (SellerID) WHERE IsCurrent = 1;

-- Grain: one row per item in a delivered order.
CREATE TABLE dw.FactSales (
    SalesKey            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactSales PRIMARY KEY,
    OrderID             VARCHAR(64)   NOT NULL,
    OrderItemID         INT           NOT NULL,
    PurchaseDateKey     INT           NOT NULL CONSTRAINT FK_FactSales_Date     REFERENCES dw.DimDate (DateKey),
    PurchaseTimestamp   DATETIME2(0)  NOT NULL,
    ProductKey          INT           NOT NULL CONSTRAINT FK_FactSales_Product  REFERENCES dw.DimProduct (ProductKey),
    CustomerKey         INT           NOT NULL CONSTRAINT FK_FactSales_Customer REFERENCES dw.DimCustomer (CustomerKey),
    SellerKey           INT           NOT NULL CONSTRAINT FK_FactSales_Seller   REFERENCES dw.DimSeller (SellerKey),
    DeliveryLocationKey INT           NOT NULL CONSTRAINT FK_FactSales_Location REFERENCES dw.DimDeliveryLocation (DeliveryLocationKey),
    ItemSalesAmount     DECIMAL(18,2) NOT NULL CONSTRAINT CK_FactSales_Sales    CHECK (ItemSalesAmount >= 0),
    FreightAmount       DECIMAL(18,2) NOT NULL CONSTRAINT CK_FactSales_Freight  CHECK (FreightAmount >= 0),
    Quantity            TINYINT       NOT NULL CONSTRAINT DF_FactSales_Qty DEFAULT 1
                                               CONSTRAINT CK_FactSales_Qty CHECK (Quantity = 1),
    IsTestData          BIT           NOT NULL,
    InsertedBatchID     INT           NOT NULL,   -- load audit fields
    LastBatchID         INT           NOT NULL,
    LastRunID           INT           NOT NULL,
    LoadedAt            DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    UpdatedAt           DATETIME2(3)  NULL,
    CONSTRAINT UQ_FactSales_Source UNIQUE (OrderID, OrderItemID));

-- Track B. Grain: one product, one purchase month, one IsTestData value.
CREATE TABLE dw.FactProductMonth (
    ProductKey         INT           NOT NULL CONSTRAINT FK_FactProductMonth_Product REFERENCES dw.DimProduct (ProductKey),
    MonthStartDateKey  INT           NOT NULL CONSTRAINT FK_FactProductMonth_Date    REFERENCES dw.DimDate (DateKey),
    IsTestData         BIT           NOT NULL,
    SalesAmount        DECIMAL(18,2) NOT NULL,
    FreightAmount      DECIMAL(18,2) NOT NULL,
    ItemCount          INT           NOT NULL,
    DistinctOrderCount INT           NOT NULL,   -- do NOT add this across products
    LastBatchID        INT           NOT NULL,
    RefreshedAt        DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_FactProductMonth PRIMARY KEY (ProductKey, MonthStartDateKey, IsTestData));
GO
/* ---------- Snowflake alternative: category is a separate table ---------- */
CREATE TABLE sf.DimCategory (
    CategoryKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sf_DimCategory PRIMARY KEY,
    CategoryCode    NVARCHAR(100) NULL CONSTRAINT UQ_sf_DimCategory_Code UNIQUE,
    CategoryLabelEN NVARCHAR(100) NOT NULL);

CREATE TABLE sf.DimProduct (
    ProductKey  INT NOT NULL CONSTRAINT PK_sf_DimProduct PRIMARY KEY     -- same key value as dw.DimProduct
                             CONSTRAINT FK_sf_DimProduct_Main REFERENCES dw.DimProduct (ProductKey),
    ProductID   VARCHAR(64) NOT NULL,
    CategoryKey INT NOT NULL CONSTRAINT FK_sf_DimProduct_Category REFERENCES sf.DimCategory (CategoryKey),
    WeightG     INT NULL,
    LengthCm    INT NULL,
    HeightCm    INT NULL,
    WidthCm     INT NULL);
GO
-- The same sales rows. Join them to sf.DimProduct with ProductKey.
CREATE VIEW sf.vwFactSales AS
SELECT SalesKey, OrderID, OrderItemID, PurchaseDateKey, PurchaseTimestamp, ProductKey, CustomerKey,
       SellerKey, DeliveryLocationKey, ItemSalesAmount, FreightAmount, Quantity, IsTestData
FROM dw.FactSales;
GO
/* ---------- unknown members ---------- */
INSERT dw.DimDate (DateKey, DateValue, [Day], [Month], [Quarter], [Year], MonthStartDate)
VALUES (0, NULL, NULL, NULL, NULL, NULL, NULL);

SET IDENTITY_INSERT dw.DimProduct ON;
INSERT dw.DimProduct (ProductKey, ProductID, CategoryCode, CategoryLabelEN, InsertedBatchID, LastBatchID)
VALUES (0, 'UNKNOWN', NULL, N'Unknown', 0, 0);
SET IDENTITY_INSERT dw.DimProduct OFF;

SET IDENTITY_INSERT dw.DimCustomer ON;
INSERT dw.DimCustomer (CustomerKey, BusinessCustomerID, InsertedBatchID) VALUES (0, 'UNKNOWN', 0);
SET IDENTITY_INSERT dw.DimCustomer OFF;

SET IDENTITY_INSERT dw.DimDeliveryLocation ON;
INSERT dw.DimDeliveryLocation (DeliveryLocationKey, City, State, InsertedBatchID) VALUES (0, N'unknown', '??', 0);
SET IDENTITY_INSERT dw.DimDeliveryLocation OFF;

SET IDENTITY_INSERT dw.DimSeller ON;
INSERT dw.DimSeller (SellerKey, SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent, InsertedBatchID, LastBatchID)
VALUES (0, 'UNKNOWN', N'unknown', '??', '??', '1900-01-01', '9999-12-31', 1, 0, 0);
SET IDENTITY_INSERT dw.DimSeller OFF;

SET IDENTITY_INSERT sf.DimCategory ON;
INSERT sf.DimCategory (CategoryKey, CategoryCode, CategoryLabelEN) VALUES (0, NULL, N'Unknown');
SET IDENTITY_INSERT sf.DimCategory OFF;

INSERT sf.DimProduct (ProductKey, ProductID, CategoryKey) VALUES (0, 'UNKNOWN', 0);
GO
/* ---------- calendar: covers purchase, delivery and review dates of the dataset ---------- */
WITH Days AS (
    SELECT CAST('2017-01-01' AS DATE) AS D
    UNION ALL
    SELECT DATEADD(DAY, 1, D) FROM Days WHERE D < '2018-12-31')
INSERT dw.DimDate (DateKey, DateValue, [Day], [Month], [Quarter], [Year], MonthStartDate)
SELECT CONVERT(INT, CONVERT(CHAR(8), D, 112)), D, DAY(D), MONTH(D), DATEPART(QUARTER, D), YEAR(D),
       DATEFROMPARTS(YEAR(D), MONTH(D), 1)
FROM Days
OPTION (MAXRECURSION 0);

SELECT COUNT(*) AS DimDateRows, MIN(DateValue) AS FirstDate, MAX(DateValue) AS LastDate FROM dw.DimDate;
GO
