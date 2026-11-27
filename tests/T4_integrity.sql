/* Integrity checks: no orphans, no duplicates, calendar coverage, snowflake row counts. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
SELECT CheckName, BadRows, IIF(BadRows = 0, 'PASS', 'FAIL') AS Result
INTO #Check
FROM (VALUES
 ('FactSales rows with a missing dimension member',
  (SELECT COUNT(*) FROM dw.FactSales f
   LEFT JOIN dw.DimDate d             ON d.DateKey = f.PurchaseDateKey
   LEFT JOIN dw.DimProduct p          ON p.ProductKey = f.ProductKey
   LEFT JOIN dw.DimCustomer c         ON c.CustomerKey = f.CustomerKey
   LEFT JOIN dw.DimSeller s           ON s.SellerKey = f.SellerKey
   LEFT JOIN dw.DimDeliveryLocation l ON l.DeliveryLocationKey = f.DeliveryLocationKey
   WHERE d.DateKey IS NULL OR p.ProductKey IS NULL OR c.CustomerKey IS NULL
      OR s.SellerKey IS NULL OR l.DeliveryLocationKey IS NULL)),
 ('Duplicate (OrderID, OrderItemID) in FactSales',
  (SELECT COUNT(*) FROM (SELECT OrderID, OrderItemID FROM dw.FactSales
                         GROUP BY OrderID, OrderItemID HAVING COUNT(*) > 1) x)),
 ('Duplicate grain in FactProductMonth',
  (SELECT COUNT(*) FROM (SELECT ProductKey, MonthStartDateKey, IsTestData FROM dw.FactProductMonth
                         GROUP BY ProductKey, MonthStartDateKey, IsTestData HAVING COUNT(*) > 1) x)),
 ('FactProductMonth keys that are not the first day of a month',
  (SELECT COUNT(*) FROM dw.FactProductMonth m JOIN dw.DimDate d ON d.DateKey = m.MonthStartDateKey
   WHERE d.[Day] <> 1)),
 ('Order, delivery or review dates missing from DimDate',
  (SELECT COUNT(*) FROM (
       SELECT CAST(PurchaseTimestamp AS DATE) AS D FROM stg.vwOrders
       UNION SELECT CAST(ApprovedAt AS DATE)  FROM stg.vwOrders
       UNION SELECT CAST(CarrierAt AS DATE)   FROM stg.vwOrders
       UNION SELECT CAST(DeliveredAt AS DATE) FROM stg.vwOrders
       UNION SELECT CAST(EstimatedAt AS DATE) FROM stg.vwOrders
       UNION SELECT CAST(CreatedAt AS DATE)   FROM stg.vwReviews
       UNION SELECT CAST(AnsweredAt AS DATE)  FROM stg.vwReviews) x
   WHERE x.D IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dw.DimDate d WHERE d.DateValue = x.D))),
 ('Real facts purchased outside 2017-01-01 to 2018-08-31',
  (SELECT COUNT(*) FROM dw.FactSales
   WHERE PurchaseTimestamp < '2017-01-01' OR PurchaseTimestamp >= '2018-09-01')),
 ('Facts from orders that are not delivered',
  (SELECT COUNT(*) FROM dw.FactSales f
   WHERE f.IsTestData = 0 AND NOT EXISTS (SELECT 1 FROM src.Orders o
                                          WHERE o.order_id = f.OrderID AND o.order_status = N'delivered'))),
 ('Snowflake view row count different from FactSales',
  ABS((SELECT COUNT(*) FROM sf.vwFactSales) - (SELECT COUNT(*) FROM dw.FactSales))),
 ('Products missing in the snowflake',
  (SELECT COUNT(*) FROM dw.DimProduct p
   WHERE NOT EXISTS (SELECT 1 FROM sf.DimProduct s WHERE s.ProductKey = p.ProductKey)))
) v (CheckName, BadRows);

SELECT * FROM #Check;

PRINT '=== Information: facts that use an unknown member (key 0) ===';
SELECT SUM(IIF(ProductKey = 0, 1, 0)) AS UnknownProduct, SUM(IIF(CustomerKey = 0, 1, 0)) AS UnknownCustomer,
       SUM(IIF(SellerKey = 0, 1, 0)) AS UnknownSeller, SUM(IIF(DeliveryLocationKey = 0, 1, 0)) AS UnknownLocation
FROM dw.FactSales;

PRINT '=== Load log ===';
SELECT RunID, BatchID, IsForced, Status, StartTime, EndTime, RowsStaged, RowsInserted, RowsUpdated, RowsRejected, ErrorText
FROM etl.LoadLog ORDER BY RunID;

IF EXISTS (SELECT 1 FROM #Check WHERE Result = 'FAIL')
    THROW 50106, 'Integrity test failed.', 1;
GO
