/* =============================================================================
   07 · Performance lab: columnstore vs rowstore, index usage, plan hygiene
   -----------------------------------------------------------------------------
   Run block by block in SSMS with "Include Actual Execution Plan" (Ctrl+M) to
   compare.  Everything created here is dropped again at the end.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

/* ---- 1. Build a rowstore twin of the fact table for a fair comparison -------- */
IF OBJECT_ID(N'fact.Transaction_Rowstore', N'U') IS NOT NULL DROP TABLE fact.Transaction_Rowstore;
SELECT * INTO fact.Transaction_Rowstore FROM fact.[Transaction];
CREATE CLUSTERED INDEX CIX_Transaction_Rowstore ON fact.Transaction_Rowstore (DateKey, AccountKey);
GO

/* ---- 2. Same aggregation, both storage engines ------------------------------ */
SET STATISTICS IO, TIME ON;
GO
PRINT '--- columnstore ---';
SELECT d.MonthKey, tt.TxnGroup, COUNT(*) AS Txns, SUM(f.Amount) AS Net
FROM fact.[Transaction] AS f
JOIN dim.Date AS d ON d.DateKey = f.DateKey
JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
GROUP BY d.MonthKey, tt.TxnGroup
ORDER BY d.MonthKey, tt.TxnGroup;
GO
PRINT '--- rowstore ---';
SELECT d.MonthKey, tt.TxnGroup, COUNT(*) AS Txns, SUM(f.Amount) AS Net
FROM fact.Transaction_Rowstore AS f
JOIN dim.Date AS d ON d.DateKey = f.DateKey
JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
GROUP BY d.MonthKey, tt.TxnGroup
ORDER BY d.MonthKey, tt.TxnGroup;
GO
SET STATISTICS IO, TIME OFF;
GO

/* ---- 3. Storage footprint: compression ratio of the columnstore ------------- */
SELECT t.name AS TableName,
       SUM(ps.row_count)                                   AS Rows_,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(10,1)) AS UsedMB
FROM sys.dm_db_partition_stats AS ps
JOIN sys.tables AS t ON t.object_id = ps.object_id
WHERE t.name IN ('Transaction', 'Transaction_Rowstore') AND SCHEMA_NAME(t.schema_id) = 'fact'
GROUP BY t.name;

/* Row-group health: aim for few, large, COMPRESSED row groups (≈1M rows each). */
SELECT rg.partition_number, rg.row_group_id, rg.state_desc, rg.total_rows, rg.deleted_rows,
       CAST(rg.size_in_bytes / 1024.0 / 1024 AS DECIMAL(10,2)) AS SizeMB
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
WHERE rg.object_id = OBJECT_ID(N'fact.[Transaction]')
ORDER BY rg.row_group_id;
GO

/* ---- 4. Point lookup: the nonclustered rowstore index on TransactionID
        turns the idempotency check into a seek instead of a columnstore scan. */
SET STATISTICS IO ON;
GO
SELECT TransactionKey, Amount FROM fact.[Transaction] WHERE TransactionID = 1000000123;                 -- seek on UX_fact_Transaction_TransactionID
SELECT TransactionKey, Amount FROM fact.[Transaction] WITH (INDEX(CCI_fact_Transaction)) WHERE TransactionID = 1000000123;  -- forced scan for comparison
GO
SET STATISTICS IO OFF;
GO

/* ---- 5. SCD2 lookups: the filtered unique index serves "current row" queries — check it is used */
SELECT c.CustomerKey, c.FullName FROM dim.Customer AS c WHERE c.CustomerID = 1234 AND c.IsCurrent = 1;
GO

/* ---- 6. Which indexes earn their keep?  (since last restart) ---------------- */
SELECT SCHEMA_NAME(o.schema_id) + '.' + o.name AS TableName, i.name AS IndexName, i.type_desc,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
FROM sys.indexes AS i
JOIN sys.objects AS o ON o.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE o.is_ms_shipped = 0 AND SCHEMA_NAME(o.schema_id) IN ('dim','fact','rpt','stg')
ORDER BY TableName, i.index_id;

/* Missing-index suggestions collected by the optimizer (treat as hints, not orders). */
SELECT TOP (10)
       mid.statement AS TableName,
       migs.avg_user_impact, migs.user_seeks,
       mid.equality_columns, mid.inequality_columns, mid.included_columns
FROM sys.dm_db_missing_index_details AS mid
JOIN sys.dm_db_missing_index_groups AS mig ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY migs.avg_user_impact * migs.user_seeks DESC;
GO

/* ---- 7. Statistics & maintenance you would schedule in production ----------- */
UPDATE STATISTICS dim.Customer WITH FULLSCAN;
UPDATE STATISTICS dim.Account  WITH FULLSCAN;
-- Reorganize closes open delta rowgroups and removes deleted rows from the columnstore
ALTER INDEX CCI_fact_Transaction ON fact.[Transaction] REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

/* ---- 8. Clean up the rowstore twin ------------------------------------------- */
DROP TABLE fact.Transaction_Rowstore;
GO
PRINT '07_performance.sql completed.';
GO
