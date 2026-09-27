/* =============================================================================
   08 · Tests — a tiny assertion framework in T-SQL (no tSQLt dependency)
   -----------------------------------------------------------------------------
   test.usp_RunAll executes ~20 assertions across the generator, the staging
   rules, SCD2 integrity, fact reconciliation, idempotency and the serving
   table.  It prints a PASS/FAIL table and THROWs if anything failed, so it can
   be wired into a CI pipeline with sqlcmd (non-zero exit on failure).
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'test.Results', N'U') IS NULL
CREATE TABLE test.Results
(
    ResultID   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_test_Results PRIMARY KEY CLUSTERED,
    RunID      INT            NOT NULL,
    TestName   VARCHAR(120)   NOT NULL,
    Passed     BIT            NOT NULL,
    Details    NVARCHAR(400)  NULL,
    TestedAt   DATETIME2(0)   NOT NULL CONSTRAINT DF_test_Results_TestedAt DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER PROCEDURE test.usp_Assert
    @RunID    INT,
    @TestName VARCHAR(120),
    @Passed   BIT,
    @Details  NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO test.Results (RunID, TestName, Passed, Details) VALUES (@RunID, @TestName, @Passed, @Details);
    PRINT CONCAT(CASE WHEN @Passed = 1 THEN '  PASS  ' ELSE '  FAIL  ' END, @TestName, CASE WHEN @Details IS NULL THEN '' ELSE ' — ' + @Details END);
END
GO

CREATE OR ALTER PROCEDURE test.usp_AssertEquals
    @RunID    INT,
    @TestName VARCHAR(120),
    @Expected SQL_VARIANT,
    @Actual   SQL_VARIANT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @passed BIT =
        CASE WHEN @Expected IS NULL AND @Actual IS NULL THEN 1
             WHEN TRY_CAST(@Expected AS DECIMAL(38,6)) IS NOT NULL AND TRY_CAST(@Actual AS DECIMAL(38,6)) IS NOT NULL
                  THEN CASE WHEN TRY_CAST(@Expected AS DECIMAL(38,6)) = TRY_CAST(@Actual AS DECIMAL(38,6)) THEN 1 ELSE 0 END
             WHEN CAST(@Expected AS NVARCHAR(200)) = CAST(@Actual AS NVARCHAR(200)) THEN 1
             ELSE 0 END;
    DECLARE @det NVARCHAR(400) = CONCAT('expected ', ISNULL(CAST(@Expected AS NVARCHAR(100)), 'NULL'), ', got ', ISNULL(CAST(@Actual AS NVARCHAR(100)), 'NULL'));
    EXEC test.usp_Assert @RunID, @TestName, @passed, @det;
END
GO

CREATE OR ALTER PROCEDURE test.usp_RunAll
    @IncludeIdempotencyRun BIT = 1        -- re-runs the incremental load to prove nothing duplicates (adds ~30-60 s)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunID INT = ISNULL((SELECT MAX(RunID) FROM test.Results), 0) + 1;
    DECLARE @n BIGINT, @m BIGINT, @d DECIMAL(18,2), @b BIT, @det NVARCHAR(400);
    PRINT CONCAT('=== test run #', @RunID, ' ===');

    /* ---- framework & generator ------------------------------------------- */
    SELECT @n = COUNT(*), @m = MAX(n) FROM etl.Numbers;
    SET @b = CASE WHEN @n = 1048576 AND @m = 1048576 THEN 1 ELSE 0 END;
    EXEC test.usp_Assert @RunID, 'etl.Numbers has 1,048,576 contiguous rows', @b;

    SELECT @b = CASE WHEN a.v = b.v AND a.v >= 0 AND a.v < 1 THEN 1 ELSE 0 END
    FROM etl.fn_Rnd('unit', 42) AS a CROSS JOIN etl.fn_Rnd('unit', 42) AS b;
    EXEC test.usp_Assert @RunID, 'etl.fn_Rnd is deterministic and within [0,1)', @b;

    ;WITH s AS (SELECT n FROM etl.Numbers WHERE n <= 20000)
    SELECT @d = 100.0 * SUM(CASE WHEN pw.label = 'A' THEN 1 ELSE 0 END) / COUNT(*)
    FROM s CROSS APPLY etl.fn_Rnd('pick', s.n) AS r CROSS APPLY etl.fn_PickWeighted('A:0.70|B:0.20|C:0.10', r.v) AS pw;
    SET @b = CASE WHEN @d BETWEEN 68.5 AND 71.5 THEN 1 ELSE 0 END;
    SET @det = CONCAT('observed ', @d, ' %');
    EXEC test.usp_Assert @RunID, 'etl.fn_PickWeighted honours weights (A ~ 70 %)', @b, @det;

    SELECT @n = COUNT(*) FROM src.CustomerExtract;
    SET @b = CASE WHEN @n BETWEEN 20000 AND 21000 THEN 1 ELSE 0 END;
    SET @det = CONCAT(@n, ' rows');
    EXEC test.usp_Assert @RunID, 'generator: ~20,000 customer rows incl. planted duplicates', @b, @det;

    SELECT @n = COUNT(*) - COUNT(DISTINCT TransactionID) FROM src.TransactionExtract WHERE TransactionID IS NOT NULL;
    SET @b = CASE WHEN @n >= 500 THEN 1 ELSE 0 END;
    SET @det = CONCAT(@n, ' duplicate rows');
    EXEC test.usp_Assert @RunID, 'generator: the 500 planted duplicate transaction rows are present', @b, @det;

    /* ---- staging rules ---------------------------------------------------- */
    SELECT @n = COUNT(*), @m = COUNT(DISTINCT CustomerID) FROM stg.Customer;
    SET @b = CASE WHEN @n = @m THEN 1 ELSE 0 END;
    EXEC test.usp_Assert @RunID, 'stg.Customer is de-duplicated (one row per CustomerID)', @b;

    SELECT @n = COUNT(*) FROM stg.Customer WHERE DATALENGTH(City) <> DATALENGTH(TRIM(City)) OR City = LOWER(City) COLLATE Latin1_General_CS_AS;
    EXEC test.usp_AssertEquals @RunID, 'stg.Customer: dirty city text normalised', 0, @n;

    SELECT @n = COUNT(*) FROM stg.Customer WHERE Gender NOT IN ('Male','Female','Unknown');
    EXEC test.usp_AssertEquals @RunID, 'stg.Customer: gender conformed to Male/Female/Unknown', 0, @n;

    SELECT @n = COUNT(*) FROM stg.Rejected WHERE SourceTable = 'src.AccountExtract' AND Reason LIKE 'Orphan%';
    SET @b = CASE WHEN @n >= 25 THEN 1 ELSE 0 END;
    SET @det = CONCAT(@n, ' rejected');
    EXEC test.usp_Assert @RunID, 'stg: the 25 planted orphan accounts were rejected', @b, @det;

    SELECT @n = COUNT(*) FROM stg.Rejected WHERE SourceTable = 'src.TransactionExtract' AND Reason LIKE '%future%';
    SET @b = CASE WHEN @n >= 100 THEN 1 ELSE 0 END;
    SET @det = CONCAT(@n, ' rejected');
    EXEC test.usp_Assert @RunID, 'stg: the 100 planted future-dated transactions were rejected', @b, @det;

    /* ---- dimensions ------------------------------------------------------- */
    SELECT @n = COUNT(*) FROM (SELECT CustomerID FROM dim.Customer WHERE CustomerKey <> -1 GROUP BY CustomerID HAVING SUM(CASE WHEN IsCurrent = 1 THEN 1 ELSE 0 END) <> 1) AS v;
    EXEC test.usp_AssertEquals @RunID, 'dim.Customer SCD2: exactly one current version per customer', 0, @n;

    SELECT @n = COUNT(*) FROM dim.Customer WHERE IsCurrent = 1 AND CustomerKey <> -1;
    SELECT @m = COUNT(*) FROM stg.Customer;
    EXEC test.usp_AssertEquals @RunID, 'dim.Customer current rows = staged customers', @m, @n;

    SELECT @n = COUNT(*) FROM dim.Customer WHERE ValidFrom >= ValidTo;
    EXEC test.usp_AssertEquals @RunID, 'dim.Customer: ValidFrom < ValidTo on every row', 0, @n;

    SELECT @n = COUNT(*) FROM dim.Date d1 WHERE NOT EXISTS (SELECT 1 FROM dim.Date d2 WHERE d2.FullDate = DATEADD(DAY, 1, d1.FullDate)) AND d1.FullDate < (SELECT MAX(FullDate) FROM dim.Date);
    EXEC test.usp_AssertEquals @RunID, 'dim.Date has no gaps', 0, @n;

    SELECT @n = COUNT(*) FROM dim.Date WHERE (DayName IN ('Friday','Saturday')) <> (IsWeekend = 1);
    EXEC test.usp_AssertEquals @RunID, 'dim.Date: Egyptian weekend flag (Fri/Sat) is consistent', 0, @n;

    /* ---- facts ------------------------------------------------------------ */
    SELECT @n = COUNT(*) - COUNT(DISTINCT TransactionID) FROM fact.[Transaction];
    EXEC test.usp_AssertEquals @RunID, 'fact.[Transaction]: no duplicate TransactionID', 0, @n;

    SELECT @n = COUNT(*) FROM fact.[Transaction] WHERE CustomerKey = -1 OR AccountKey = -1 OR ChannelKey = -1 OR TxnTypeKey = -1;
    EXEC test.usp_AssertEquals @RunID, 'fact.[Transaction]: every surrogate key resolved', 0, @n;

    SELECT @n = COUNT(*) FROM fact.[Transaction] f
    JOIN dim.Customer c ON c.CustomerKey = f.CustomerKey
    JOIN dim.Date d ON d.DateKey = f.DateKey
    WHERE NOT (CAST(d.FullDate AS DATETIME2(0)) >= c.ValidFrom AND CAST(d.FullDate AS DATETIME2(0)) < c.ValidTo);
    EXEC test.usp_AssertEquals @RunID, 'fact.[Transaction]: CustomerKey is the SCD2 version valid on the txn date', 0, @n;

    SELECT @n = COUNT(*) FROM audit.DataQualityResult WHERE LoadID = (SELECT MAX(LoadID) FROM audit.DataQualityResult) AND Status = 'FAIL';
    EXEC test.usp_AssertEquals @RunID, 'audit: latest data-quality gate has no FAIL', 0, @n;

    SELECT @n = COUNT(*) FROM (SELECT s.AccountKey, s.ClosingBalance, ISNULL(t.Total, 0) AS Total
                               FROM fact.AccountMonthSnapshot s
                               JOIN (SELECT AccountKey, MAX(MonthKey) AS mk FROM fact.AccountMonthSnapshot GROUP BY AccountKey) lm ON lm.AccountKey = s.AccountKey AND lm.mk = s.MonthKey
                               LEFT JOIN (SELECT AccountKey, SUM(Amount) AS Total FROM fact.[Transaction] GROUP BY AccountKey) t ON t.AccountKey = s.AccountKey) v
    WHERE ABS(v.ClosingBalance - v.Total) >= 0.01;
    EXEC test.usp_AssertEquals @RunID, 'snapshot: closing balance reconciles to transactions for every account', 0, @n;

    SELECT @n = COUNT(*) FROM fact.AccountMonthSnapshot s WHERE s.OpeningBalance <> ISNULL((SELECT p.ClosingBalance FROM fact.AccountMonthSnapshot p WHERE p.AccountKey = s.AccountKey AND p.MonthKey = (SELECT MAX(MonthKey) FROM fact.AccountMonthSnapshot x WHERE x.AccountKey = s.AccountKey AND x.MonthKey < s.MonthKey)), 0);
    EXEC test.usp_AssertEquals @RunID, 'snapshot: opening balance = previous closing balance', 0, @n;

    /* ---- serving ---------------------------------------------------------- */
    SELECT @d = 100.0 * AVG(CAST(IsChurned AS DECIMAL(3,1))) FROM rpt.Customer360;
    SET @b = CASE WHEN @d BETWEEN 5 AND 30 THEN 1 ELSE 0 END;
    SET @det = CONCAT(CAST(@d AS DECIMAL(5,1)), ' %');
    EXEC test.usp_Assert @RunID, 'rpt.Customer360: churn rate is plausible (5-30 %)', @b, @det;

    SELECT @n = COUNT(*) FROM rpt.Customer360 WHERE RecencyScore NOT BETWEEN 1 AND 5 OR FrequencyScore NOT BETWEEN 1 AND 5 OR MonetaryScore NOT BETWEEN 1 AND 5;
    EXEC test.usp_AssertEquals @RunID, 'rpt.Customer360: RFM scores are 1..5', 0, @n;

    SELECT @n = COUNT(*) FROM rpt.Customer360 WHERE IsChurned = 1 AND ChurnRiskBand <> 'High';
    EXEC test.usp_AssertEquals @RunID, 'rpt.Customer360: every churned customer is High risk', 0, @n;

    /* ---- idempotency: re-running the incremental load must not add rows --- */
    IF @IncludeIdempotencyRun = 1
    BEGIN
        DECLARE @before BIGINT = (SELECT COUNT(*) FROM fact.[Transaction]);
        DECLARE @beforeDim INT = (SELECT COUNT(*) FROM dim.Customer);
        DECLARE @asOf DATE = (SELECT MAX(CAST(CreatedAt AS DATE)) FROM src.TransactionExtract);
        EXEC etl.usp_RunFullLoad @Mode = 'Incremental', @AsOfDate = @asOf, @FailOnDQ = 0;
        SELECT @n = COUNT(*) FROM fact.[Transaction];
        EXEC test.usp_AssertEquals @RunID, 'idempotency: re-running the incremental load adds no fact rows', @before, @n;
        SELECT @n = COUNT(*) FROM dim.Customer;
        EXEC test.usp_AssertEquals @RunID, 'idempotency: unchanged customers get no new SCD2 versions', @beforeDim, @n;
    END

    /* ---- summary ---------------------------------------------------------- */
    SELECT TestName, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, Details
    FROM test.Results WHERE RunID = @RunID ORDER BY ResultID;

    DECLARE @failed INT = (SELECT COUNT(*) FROM test.Results WHERE RunID = @RunID AND Passed = 0);
    DECLARE @total  INT = (SELECT COUNT(*) FROM test.Results WHERE RunID = @RunID);
    PRINT CONCAT('=== ', @total - @failed, '/', @total, ' tests passed ===');
    IF @failed > 0
    BEGIN
        DECLARE @msg NVARCHAR(2000) = CONCAT(@failed, ' test(s) failed: ',
            (SELECT STRING_AGG(TestName, '; ') FROM test.Results WHERE RunID = @RunID AND Passed = 0));
        THROW 50002, @msg, 1;
    END
END
GO

PRINT '08_tests.sql completed: test.usp_RunAll ready.  Run:  EXEC test.usp_RunAll;';
GO
