/* DimSeller: Slowly Changing Dimensions.
   Type 0  OriginalSellerState: set once, never changed. An attempt is logged and ignored.
   Type 2  City/State: close the current row and insert a new version.
   Effective dates are business dates. LoadedAt and BatchID only say when the row was loaded.
   A version is valid when ValidFrom <= date < ValidTo.                                    */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;   -- required: DimSeller has a filtered index
SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadDimSeller @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT, @Updated INT, @Rejected INT;
    DECLARE @BatchStart DATETIME2(0) = (SELECT PurchaseFrom FROM etl.Batch WHERE BatchID = @BatchID);

    SELECT SellerID, City, State, OriginalSellerState, EffectiveAt, IsExplicitChange
    INTO #Seller
    FROM stg.vwSellers WHERE BatchID = @BatchID;

    /* Type 0: log an attempt to change the original state. Nothing is updated. */
    INSERT etl.DataIssue (RunID, BatchID, TableName, SourceKey, IssueType, Reason)
    SELECT @RunID, @BatchID, N'dw.DimSeller', s.SellerID, 'SCD0_IGNORED',
           CONCAT(N'OriginalSellerState stays ', d.OriginalSellerState, N'; incoming value ', s.OriginalSellerState, N' ignored')
    FROM #Seller s
    JOIN dw.DimSeller d ON d.SellerID = s.SellerID AND d.IsCurrent = 1
    WHERE s.IsExplicitChange = 1 AND s.OriginalSellerState <> d.OriginalSellerState
      AND NOT EXISTS (SELECT 1 FROM etl.DataIssue x          -- a replay does not log it twice
                      WHERE x.IssueType = 'SCD0_IGNORED' AND x.BatchID = @BatchID AND x.SourceKey = s.SellerID);

    /* Sellers whose location differs from the current version */
    SELECT s.SellerID, s.City, s.State, s.EffectiveAt, d.SellerKey AS OldSellerKey,
           d.ValidFrom AS OldValidFrom, d.OriginalSellerState
    INTO #Change
    FROM #Seller s
    JOIN dw.DimSeller d ON d.SellerID = s.SellerID AND d.IsCurrent = 1
    WHERE EXISTS (SELECT s.City, s.State EXCEPT SELECT d.City, d.State);

    -- A change needs a business effective date later than the current version starts.
    INSERT etl.DataIssue (RunID, BatchID, TableName, SourceKey, IssueType, Reason)
    SELECT @RunID, @BatchID, N'dw.DimSeller', SellerID, 'REJECT',
           N'Location change without an effective date after the current ValidFrom'
    FROM #Change WHERE EffectiveAt IS NULL OR EffectiveAt <= OldValidFrom;
    SET @Rejected = @@ROWCOUNT;
    DELETE FROM #Change WHERE EffectiveAt IS NULL OR EffectiveAt <= OldValidFrom;

    /* Type 2, step 1: expire the old version */
    UPDATE d
    SET ValidTo = c.EffectiveAt, IsCurrent = 0, LastBatchID = @BatchID, UpdatedAt = SYSDATETIME()
    FROM dw.DimSeller d JOIN #Change c ON c.OldSellerKey = d.SellerKey;
    SET @Updated = @@ROWCOUNT;

    /* Type 2, step 2: insert the new version. OriginalSellerState is copied (Type 0). */
    INSERT dw.DimSeller (SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent,
                         InsertedBatchID, LastBatchID)
    SELECT SellerID, City, State, OriginalSellerState, EffectiveAt, '9999-12-31', 1, @BatchID, @BatchID
    FROM #Change;
    SET @Inserted = @@ROWCOUNT;

    /* New sellers. B1 starts on 2017-01-01 (teaching baseline). Later batches start at the first
       purchase in the batch, or at an earlier effective date when one is supplied.            */
    SELECT i.SellerID, MIN(o.PurchaseTimestamp) AS FirstPurchase
    INTO #FirstSale                       -- calculated once, then joined (much faster than a CTE here)
    FROM stg.vwOrderItems i
    JOIN stg.vwOrders o ON o.BatchID = i.BatchID AND o.OrderID = i.OrderID
    WHERE i.BatchID = @BatchID
    GROUP BY i.SellerID;

    INSERT dw.DimSeller (SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent,
                         InsertedBatchID, LastBatchID)
    SELECT s.SellerID, s.City, s.State, s.State,
           CASE WHEN @BatchID = 1 THEN CAST('2017-01-01' AS DATETIME2(0))
                WHEN s.EffectiveAt < f.FirstPurchase THEN s.EffectiveAt
                ELSE COALESCE(f.FirstPurchase, s.EffectiveAt, @BatchStart) END,
           '9999-12-31', 1, @BatchID, @BatchID
    FROM #Seller s
    LEFT JOIN #FirstSale f ON f.SellerID = s.SellerID
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimSeller d WHERE d.SellerID = s.SellerID);
    SET @Inserted += @@ROWCOUNT;

    /* Check: effective periods of one seller must not overlap */
    IF EXISTS (SELECT 1 FROM dw.DimSeller a
               JOIN dw.DimSeller b ON b.SellerID = a.SellerID AND b.SellerKey > a.SellerKey
               WHERE a.ValidFrom < b.ValidTo AND b.ValidFrom < a.ValidTo)
        THROW 50010, 'DimSeller has overlapping effective periods.', 1;

    EXEC etl.usp_LogTable @RunID, N'dw.DimSeller', @Inserted, @Updated, @Rejected;
END;
GO
