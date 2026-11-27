/* B1: initial full load. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
EXEC etl.usp_RunBatch @BatchID = 1;
EXEC etl.usp_CheckBatch 1;

SELECT SellerKey, SellerID, City, State, OriginalSellerState, ValidFrom, ValidTo, IsCurrent
FROM dw.DimSeller WHERE SellerID = 'LAB_SELLER_01' ORDER BY ValidFrom;

SELECT BatchID, TableName, IssueType, SourceKey, Reason
FROM etl.DataIssue WHERE BatchID = 1 ORDER BY IssueID;
GO
