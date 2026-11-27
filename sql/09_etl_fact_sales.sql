/* ETL steps 4 and 5: resolve surrogate keys and load dw.FactSales.
   Only items of delivered orders are loaded. Items, payments and reviews are never joined here.
   SellerKey = the seller version valid at the purchase time, even if the order arrives late.
   Existing facts: only changed amounts are updated, so their keys are kept.                  */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadFactSales @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT, @Updated INT;

    SELECT i.OrderID, i.OrderItemID,
           CONVERT(INT, CONVERT(CHAR(8), o.PurchaseTimestamp, 112)) AS PurchaseDateKey,
           o.PurchaseTimestamp,
           ISNULL(p.ProductKey, 0)          AS ProductKey,
           ISNULL(c.CustomerKey, 0)         AS CustomerKey,
           ISNULL(s.SellerKey, 0)           AS SellerKey,
           ISNULL(l.DeliveryLocationKey, 0) AS DeliveryLocationKey,
           i.ItemSalesAmount, i.FreightAmount, i.IsTestData
    INTO #Source
    FROM stg.vwOrderItems i
    JOIN stg.vwOrders o
         ON o.BatchID = i.BatchID AND o.OrderID = i.OrderID AND o.OrderStatus = 'delivered'
    LEFT JOIN stg.vwCustomers cu ON cu.BatchID = o.BatchID AND cu.CustomerID = o.CustomerID
    LEFT JOIN dw.DimCustomer c   ON c.BusinessCustomerID = cu.BusinessCustomerID
    LEFT JOIN dw.DimDeliveryLocation l ON l.City = cu.City AND l.State = cu.State  -- location of THIS order
    LEFT JOIN dw.DimProduct p    ON p.ProductID = i.ProductID
    LEFT JOIN dw.DimSeller s     ON s.SellerID = i.SellerID
                                AND o.PurchaseTimestamp >= s.ValidFrom
                                AND o.PurchaseTimestamp <  s.ValidTo
    WHERE i.BatchID = @BatchID;

    CREATE UNIQUE CLUSTERED INDEX CIX_Source ON #Source (OrderID, OrderItemID);

    -- Changed amounts on existing source pairs
    UPDATE f
    SET ItemSalesAmount = s.ItemSalesAmount, FreightAmount = s.FreightAmount,
        LastBatchID = @BatchID, LastRunID = @RunID, UpdatedAt = SYSDATETIME()
    FROM dw.FactSales f
    JOIN #Source s ON s.OrderID = f.OrderID AND s.OrderItemID = f.OrderItemID
    WHERE f.ItemSalesAmount <> s.ItemSalesAmount OR f.FreightAmount <> s.FreightAmount;
    SET @Updated = @@ROWCOUNT;

    -- New source pairs
    INSERT dw.FactSales (OrderID, OrderItemID, PurchaseDateKey, PurchaseTimestamp, ProductKey, CustomerKey,
                         SellerKey, DeliveryLocationKey, ItemSalesAmount, FreightAmount, IsTestData,
                         InsertedBatchID, LastBatchID, LastRunID)
    SELECT s.OrderID, s.OrderItemID, s.PurchaseDateKey, s.PurchaseTimestamp, s.ProductKey, s.CustomerKey,
           s.SellerKey, s.DeliveryLocationKey, s.ItemSalesAmount, s.FreightAmount, s.IsTestData,
           @BatchID, @BatchID, @RunID
    FROM #Source s
    WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales f WHERE f.OrderID = s.OrderID AND f.OrderItemID = s.OrderItemID);
    SET @Inserted = @@ROWCOUNT;

    EXEC etl.usp_LogTable @RunID, N'dw.FactSales', @Inserted, @Updated;
END;
GO
