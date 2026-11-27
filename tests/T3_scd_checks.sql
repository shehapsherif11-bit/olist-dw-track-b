/* SCD checks. Run after B3. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== LAB seller versions ===';
SELECT SellerKey, SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent, InsertedBatchID, LoadedAt
FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01' ORDER BY ValidFrom;

PRINT '=== LAB facts and the seller version they use ===';
SELECT f.OrderID, f.PurchaseTimestamp, f.InsertedBatchID, f.SellerKey, s.State, s.ValidFrom, s.ValidTo
FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
WHERE f.IsTestData = 1 ORDER BY f.PurchaseTimestamp;

SELECT CheckName, BadRows, IIF(BadRows = 0, 'PASS', 'FAIL') AS Result
INTO #Check
FROM (VALUES
 ('Sellers without exactly one current row',
  (SELECT COUNT(*) FROM (SELECT SellerID FROM dw.DimSeller GROUP BY SellerID
                         HAVING SUM(CAST(IsCurrent AS INT)) <> 1) x)),
 ('Overlapping effective periods',
  (SELECT COUNT(*) FROM dw.DimSeller a JOIN dw.DimSeller b ON b.SellerID = a.SellerID AND b.SellerKey > a.SellerKey
   WHERE a.ValidFrom < b.ValidTo AND b.ValidFrom < a.ValidTo)),
 ('Sellers whose OriginalSellerState differs between versions',
  (SELECT COUNT(*) FROM (SELECT SellerID FROM dw.DimSeller GROUP BY SellerID
                         HAVING COUNT(DISTINCT OriginalSellerState) > 1) x)),
 ('Real sellers with more than one version (static source)',
  (SELECT COUNT(*) FROM (SELECT SellerID FROM dw.DimSeller WHERE SellerID <> 'LAB_SELLER_01'
                         GROUP BY SellerID HAVING COUNT(*) > 1) x)),
 ('Facts outside their seller version period',
  (SELECT COUNT(*) FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
   WHERE NOT (f.PurchaseTimestamp >= s.ValidFrom AND f.PurchaseTimestamp < s.ValidTo))),
 ('LAB_ORDER_01 and LAB_ORDER_03 not on the SP version',
  (SELECT COUNT(*) FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
   WHERE f.OrderID IN ('LAB_ORDER_01', 'LAB_ORDER_03') AND s.State <> 'SP')),
 ('LAB_ORDER_02 not on the RJ version',
  (SELECT COUNT(*) FROM dw.FactSales f JOIN dw.DimSeller s ON s.SellerKey = f.SellerKey
   WHERE f.OrderID = 'LAB_ORDER_02' AND s.State <> 'RJ')),
 ('lab_training products without the corrected label',
  (SELECT COUNT(*) FROM dw.DimProduct WHERE CategoryCode = N'lab_training' AND CategoryLabelEN <> N'Training')),
 ('LAB products with more than one ProductKey',
  (SELECT COUNT(*) FROM (SELECT ProductID FROM dw.DimProduct GROUP BY ProductID HAVING COUNT(*) > 1) x))
) v (CheckName, BadRows);

SELECT * FROM #Check;
IF EXISTS (SELECT 1 FROM #Check WHERE Result = 'FAIL')
    THROW 50105, 'SCD test failed.', 1;
GO
