/* =============================================================================
   run_all.sql — execute the whole project in order (SSMS: Query ▸ SQLCMD Mode)
   -----------------------------------------------------------------------------
   Usage in SSMS : enable SQLCMD Mode, set the path below, press F5.
   Usage in shell: sqlcmd -S localhost -E -i sql\run_all.sql -v ProjectPath="C:\repos\bank-customer360-tsql\sql"
   Expected runtime on a laptop: 3–6 minutes (most of it is the 1M-row generator).
   ============================================================================= */
:setvar ProjectPath "C:\repos\bank-customer360-tsql\sql"
:on error exit

PRINT '>> 00 database, schemas, helpers';
:r $(ProjectPath)\00_create_database.sql
PRINT '>> 01 landing tables';
:r $(ProjectPath)\01_source_extracts.sql
PRINT '>> 02 synthetic source data (1–3 min)';
:r $(ProjectPath)\02_generate_source_data.sql
PRINT '>> 03 warehouse tables';
:r $(ProjectPath)\03_warehouse_tables.sql
PRINT '>> 04 ETL procedures';
:r $(ProjectPath)\04_etl_procedures.sql
PRINT '>> 05 serving views';
:r $(ProjectPath)\05_analytics_views.sql

PRINT '>> initial full load';
USE BankDW;
GO
EXEC etl.usp_RunFullLoad @Mode = 'Full';
GO

PRINT '>> 08 tests';
:r $(ProjectPath)\08_tests.sql
EXEC test.usp_RunAll @IncludeIdempotencyRun = 1;
GO

PRINT '>> done. Optional: 06_analytics_queries.sql, 07_performance.sql, 09_incremental_demo.sql';
