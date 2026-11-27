/* Batch manifest export: every LAB record, and record counts for the real Olist data.
   The full manifest is the view etl.vwBatchManifest. */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== LAB records (all) ===';
SELECT b.BatchName, m.TableName, m.SourceKey, m.Operation, m.ChangeSeq, m.EffectiveAt
FROM etl.vwBatchManifest m JOIN etl.Batch b ON b.BatchID = m.BatchID
WHERE m.IsTestData = 1
ORDER BY m.BatchID, m.ChangeSeq, m.TableName, m.SourceKey;

PRINT '=== Real Olist records (counts) ===';
SELECT b.BatchName, m.TableName, m.Operation, COUNT(*) AS Records,
       MIN(m.ChangeSeq) AS FirstChangeSeq, MAX(m.ChangeSeq) AS LastChangeSeq
FROM etl.vwBatchManifest m JOIN etl.Batch b ON b.BatchID = m.BatchID
WHERE m.IsTestData = 0
GROUP BY b.BatchName, m.BatchID, m.TableName, m.Operation
ORDER BY m.BatchID, m.TableName, m.Operation;
GO
