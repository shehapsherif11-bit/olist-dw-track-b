/* ETL step 3: load the dimensions (except DimSeller, see 08) and the snowflake tables.
   Surrogate keys never change: existing rows are updated, new members are inserted.
   "EXISTS (SELECT new values EXCEPT SELECT old values)" is true only when a value changed,
   and it treats two NULLs as equal.                                                     */
USE OlistDW_Project;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- Saves the row counts of one target table for one run.
CREATE OR ALTER PROCEDURE etl.usp_LogTable
    @RunID INT, @TargetTable NVARCHAR(128), @Inserted INT = 0, @Updated INT = 0, @Rejected INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    INSERT etl.LoadLogDetail (RunID, TargetTable, RowsInserted, RowsUpdated, RowsRejected)
    VALUES (@RunID, @TargetTable, @Inserted, @Updated, @Rejected);
END;
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadDimProduct @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT, @Updated INT;

    -- SCD Type 1: a corrected category label overwrites the old label on every product of that category.
    UPDATE p
    SET CategoryLabelEN = c.CategoryLabelEN, LastBatchID = @BatchID, UpdatedAt = SYSDATETIME()
    FROM dw.DimProduct p
    JOIN stg.vwCategories c ON c.BatchID = @BatchID AND c.CategoryCode = p.CategoryCode
    WHERE p.CategoryLabelEN <> c.CategoryLabelEN;
    SET @Updated = @@ROWCOUNT;

    SELECT s.ProductID, s.CategoryCode,
           CASE WHEN s.CategoryCode IS NULL THEN N'Unknown'
                ELSE COALESCE(c.CategoryLabelEN, s.CategoryCode) END AS CategoryLabelEN,
           s.WeightG, s.LengthCm, s.HeightCm, s.WidthCm
    INTO #Product
    FROM stg.vwProducts s
    LEFT JOIN stg.vwCategories c ON c.BatchID = s.BatchID AND c.CategoryCode = s.CategoryCode
    WHERE s.BatchID = @BatchID;

    UPDATE d
    SET CategoryCode = s.CategoryCode, CategoryLabelEN = s.CategoryLabelEN, WeightG = s.WeightG,
        LengthCm = s.LengthCm, HeightCm = s.HeightCm, WidthCm = s.WidthCm,
        LastBatchID = @BatchID, UpdatedAt = SYSDATETIME()
    FROM dw.DimProduct d
    JOIN #Product s ON s.ProductID = d.ProductID
    WHERE EXISTS (SELECT s.CategoryCode, s.CategoryLabelEN, s.WeightG, s.LengthCm, s.HeightCm, s.WidthCm
                  EXCEPT
                  SELECT d.CategoryCode, d.CategoryLabelEN, d.WeightG, d.LengthCm, d.HeightCm, d.WidthCm);
    SET @Updated += @@ROWCOUNT;

    INSERT dw.DimProduct (ProductID, CategoryCode, CategoryLabelEN, WeightG, LengthCm, HeightCm, WidthCm,
                          InsertedBatchID, LastBatchID)
    SELECT s.ProductID, s.CategoryCode, s.CategoryLabelEN, s.WeightG, s.LengthCm, s.HeightCm, s.WidthCm,
           @BatchID, @BatchID
    FROM #Product s
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimProduct d WHERE d.ProductID = s.ProductID);
    SET @Inserted = @@ROWCOUNT;

    EXEC etl.usp_LogTable @RunID, N'dw.DimProduct', @Inserted, @Updated;
END;
GO
-- One row per person (customer_unique_id), not per customer_id.
CREATE OR ALTER PROCEDURE etl.usp_LoadDimCustomer @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT;

    INSERT dw.DimCustomer (BusinessCustomerID, InsertedBatchID)
    SELECT DISTINCT s.BusinessCustomerID, @BatchID
    FROM stg.vwCustomers s
    WHERE s.BatchID = @BatchID
      AND NOT EXISTS (SELECT 1 FROM dw.DimCustomer d WHERE d.BusinessCustomerID = s.BusinessCustomerID);
    SET @Inserted = @@ROWCOUNT;

    EXEC etl.usp_LogTable @RunID, N'dw.DimCustomer', @Inserted;
END;
GO
-- One row per normalized (City, State) pair.
CREATE OR ALTER PROCEDURE etl.usp_LoadDimDeliveryLocation @BatchID INT, @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT;

    INSERT dw.DimDeliveryLocation (City, State, InsertedBatchID)
    SELECT DISTINCT s.City, s.State, @BatchID
    FROM stg.vwCustomers s
    WHERE s.BatchID = @BatchID AND s.City IS NOT NULL AND s.State IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dw.DimDeliveryLocation d WHERE d.City = s.City AND d.State = s.State);
    SET @Inserted = @@ROWCOUNT;

    EXEC etl.usp_LogTable @RunID, N'dw.DimDeliveryLocation', @Inserted;
END;
GO
-- Snowflake: the category label is stored once in sf.DimCategory.
CREATE OR ALTER PROCEDURE etl.usp_LoadSnowflake @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Inserted INT, @Updated INT;

    SELECT DISTINCT CategoryCode, CategoryLabelEN INTO #Category
    FROM dw.DimProduct WHERE CategoryCode IS NOT NULL;

    UPDATE c SET CategoryLabelEN = s.CategoryLabelEN          -- Type 1: one row per category changes
    FROM sf.DimCategory c JOIN #Category s ON s.CategoryCode = c.CategoryCode
    WHERE c.CategoryLabelEN <> s.CategoryLabelEN;
    SET @Updated = @@ROWCOUNT;

    INSERT sf.DimCategory (CategoryCode, CategoryLabelEN)
    SELECT s.CategoryCode, s.CategoryLabelEN FROM #Category s
    WHERE NOT EXISTS (SELECT 1 FROM sf.DimCategory c WHERE c.CategoryCode = s.CategoryCode);
    SET @Inserted = @@ROWCOUNT;
    EXEC etl.usp_LogTable @RunID, N'sf.DimCategory', @Inserted, @Updated;

    SELECT p.ProductKey, p.ProductID, ISNULL(c.CategoryKey, 0) AS CategoryKey,
           p.WeightG, p.LengthCm, p.HeightCm, p.WidthCm
    INTO #Product
    FROM dw.DimProduct p
    LEFT JOIN sf.DimCategory c ON c.CategoryCode = p.CategoryCode
    WHERE p.ProductKey <> 0;

    UPDATE t
    SET CategoryKey = s.CategoryKey, WeightG = s.WeightG, LengthCm = s.LengthCm,
        HeightCm = s.HeightCm, WidthCm = s.WidthCm
    FROM sf.DimProduct t JOIN #Product s ON s.ProductKey = t.ProductKey
    WHERE EXISTS (SELECT s.CategoryKey, s.WeightG, s.LengthCm, s.HeightCm, s.WidthCm
                  EXCEPT
                  SELECT t.CategoryKey, t.WeightG, t.LengthCm, t.HeightCm, t.WidthCm);
    SET @Updated = @@ROWCOUNT;

    INSERT sf.DimProduct (ProductKey, ProductID, CategoryKey, WeightG, LengthCm, HeightCm, WidthCm)
    SELECT s.ProductKey, s.ProductID, s.CategoryKey, s.WeightG, s.LengthCm, s.HeightCm, s.WidthCm
    FROM #Product s
    WHERE NOT EXISTS (SELECT 1 FROM sf.DimProduct t WHERE t.ProductKey = s.ProductKey);
    SET @Inserted = @@ROWCOUNT;
    EXEC etl.usp_LogTable @RunID, N'sf.DimProduct', @Inserted, @Updated;
END;
GO
