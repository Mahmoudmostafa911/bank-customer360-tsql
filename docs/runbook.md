# Runbook

## Requirements

* SQL Server 2017 or later (Developer or Express edition is fine) **or** Azure SQL Database.
  The scripts use `STRING_AGG`, `CONCAT_WS`, `TRIM`, `CREATE OR ALTER`, `FOR JSON`, `THROW`, sequences,
  clustered columnstore and `PERCENTILE_CONT`.
* SSMS 18+ (for SQLCMD mode) or `sqlcmd` on the path.
* About 1 GB free for data, log and tempdb during the generator step.
* The login needs `CREATE DATABASE` (or an existing empty database named `BankDW` on Azure SQL — comment
  out the `CREATE DATABASE` block in `00_create_database.sql`).

## Running everything

### SSMS

1. Open `sql/run_all.sql`.
2. *Query ▸ SQLCMD Mode*.
3. Change `:setvar ProjectPath "C:\repos\bank-customer360-tsql\sql"` to your folder.
4. F5. The Messages tab shows `>> 00 …` through `>> 08 tests`, then the test summary.

### PowerShell

```powershell
cd sql
.\run_all.ps1 -Server localhost                        # trusted connection
.\run_all.ps1 -Server "localhost\SQLEXPRESS"            # named instance
.\run_all.ps1 -Server . -User sa -Password '***'        # SQL login
.\run_all.ps1 -SkipTests                                # build only
```

### Script by script (if you prefer to watch each step)

| Order | Script | What to expect |
|---|---|---|
| 1 | `00_create_database.sql` | database `BankDW`, 8 schemas, `etl.Numbers` (1,048,576 rows), two functions, load framework |
| 2 | `01_source_extracts.sql` | 6 empty landing tables |
| 3 | `02_generate_source_data.sql` | 1–3 min. Prints row counts: ~20,090 customers, ~32,000 accounts, ~1,000,000 transactions, ~6,000 complaints |
| 4 | `03_warehouse_tables.sql` | staging, 7 dimensions with unknown members, 3 facts, audit, serving table |
| 5 | `04_etl_procedures.sql` | 13 procedures in `etl` |
| 6 | `05_analytics_views.sql` | 8 views in `rpt` |
| 7 | `EXEC etl.usp_RunFullLoad @Mode = 'Full';` | 1–3 min. Returns the `etl.LoadLog` rows of the run (one per step, status *Succeeded*) |
| 8 | `08_tests.sql` then `EXEC test.usp_RunAll @IncludeIdempotencyRun = 1;` | 26 assertions, summary `26 passed, 0 failed` |
| 9 | `06_analytics_queries.sql` | 12 result sets |
| 10 | `07_performance.sql` | timings for columnstore vs rowstore, aggregate pushdown, index sizes |
| 11 | `09_incremental_demo.sql` | inserts "day 2" source rows, runs two incremental loads, shows SCD2 history and zero-change re-run |
| — | `99_cleanup.sql` | drops `BankDW` |

## Checking the result

```sql
USE BankDW;

-- one row per step of the last load
SELECT * FROM rpt.vw_LoadRuns ORDER BY LoadID DESC, StartedAt;

-- the quality gate
SELECT CheckName, Severity, Status, Observed, Expected, Details FROM rpt.vw_DataQualityLatest;

-- the tests
SELECT TestName, Passed, Details FROM test.Results WHERE RunID = (SELECT MAX(RunID) FROM test.Results);

-- row counts
SELECT 'dim.Customer' AS t, COUNT(*) FROM dim.Customer UNION ALL
SELECT 'dim.Account',        COUNT(*) FROM dim.Account   UNION ALL
SELECT 'fact.Transaction',   COUNT(*) FROM fact.Transaction UNION ALL
SELECT 'fact.AccountMonthSnapshot', COUNT(*) FROM fact.AccountMonthSnapshot UNION ALL
SELECT 'fact.Complaint',     COUNT(*) FROM fact.Complaint UNION ALL
SELECT 'rpt.Customer360',    COUNT(*) FROM rpt.Customer360 UNION ALL
SELECT 'stg.Rejected',       COUNT(*) FROM stg.Rejected;
```

## Operating the load

| Task | Command |
|---|---|
| Full rebuild of the facts | `EXEC etl.usp_RunFullLoad @Mode = 'Full';` |
| Daily delta | `EXEC etl.usp_RunFullLoad @Mode = 'Incremental';` |
| Load as of a given business date | `EXEC etl.usp_RunFullLoad @Mode = 'Incremental', @AsOfDate = '2026-01-15';` |
| Record quality failures without aborting | `EXEC etl.usp_RunFullLoad @Mode = 'Incremental', @FailOnDQ = 0;` |
| Re-run one step | `DECLARE @id INT = NEXT VALUE FOR etl.LoadSeq; EXEC etl.usp_RefreshCustomer360 @LoadID = @id, @SnapshotDate = '2025-12-31';` |
| Inspect rejects | `SELECT Reason, COUNT(*) FROM stg.Rejected GROUP BY Reason;` |

`@AsOfDate` defaults to the latest `CreatedAt` date in the transaction extract, so the synthetic history
(ending 31 Dec 2025) is analysed as of that date rather than today.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Incorrect syntax near ':'` on `:r` or `:setvar` | SQLCMD mode is off in SSMS — *Query ▸ SQLCMD Mode* |
| `Could not find file …\00_create_database.sql` | `ProjectPath` in `run_all.sql` does not point to the `sql` folder (the .ps1 resolves its own folder) |
| `There is already an object named '#Geo'` when re-running `02_…` | you stopped a previous run half-way; run `DROP TABLE #Geo, #FirstNames, #LastNames, #Cust, #Acct, #TxnAcct, #Txn;` or open a new query window |
| `Data-quality gate failed (…)` error 50001 | the gate found a FAIL check. `SELECT * FROM rpt.vw_DataQualityLatest WHERE Status = 'FAIL'` shows which; `@FailOnDQ = 0` records instead of aborting |
| `String or binary data would be truncated` | a landing value longer than the staging column — the row should have been rejected; check `stg.Rejected` and the `TRY_CONVERT`/`LEFT()` in the staging procedure |
| Generator takes more than 5 minutes | tempdb or log on a slow disk; set `BankDW` to SIMPLE recovery (already the default in `00`) and make sure autogrowth is not in tiny steps |
| Azure SQL: `CREATE DATABASE` not permitted in this context | create `BankDW` from the portal first and run the scripts inside it |
| `DATENAME` returns non-English day names | the session language is not English; `SET LANGUAGE us_english;` before `04_…` |
| Tests: `generator: ~20,000 customer rows …` fails after running `09_incremental_demo.sql` | the demo adds source rows; the assertion tolerates up to 21,000 — re-run the generator (`02`) for a clean baseline |

## Resetting

```sql
EXEC etl.usp_RunFullLoad @Mode = 'Full';   -- rebuild the warehouse from the landing tables
-- or
:r 99_cleanup.sql                          -- drop the database and start over
```
