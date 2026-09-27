/* =============================================================================
   04 · ETL procedures (schema etl)
   -----------------------------------------------------------------------------
   Load order (orchestrated by etl.usp_RunFullLoad):
     1 usp_LoadDimDate            static calendar, idempotent
     2 usp_LoadReferenceDims      dim.Product, dim.Branch (SCD1 MERGE)
     3 usp_StageCustomers         cleanse + de-duplicate + reject → stg.Customer / stg.Rejected
     4 usp_LoadDimCustomer        SCD Type 2 with MERGE + OUTPUT
     5 usp_StageAccounts          cleanse + referential checks
     6 usp_LoadDimAccount         SCD Type 1 MERGE
     7 usp_StageTransactions      incremental extract by watermark, validation, de-dup
     8 usp_LoadFactTransaction    surrogate-key lookups incl. point-in-time SCD2 → fact, watermark
     9 usp_LoadFactComplaint      MERGE on business key
    10 usp_BuildAccountMonthSnapshot   periodic snapshot with running balances (window functions)
    11 usp_RefreshCustomer360     serving table: RFM, churn flag, risk band
    12 usp_RunDataQuality         gate → audit.DataQualityResult, THROW on FAIL
   Every procedure reports its row counts through OUTPUT parameters so the
   orchestrator can log them; every procedure is safe to re-run.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

/* ───────────────────────────── 1 · dim.Date ─────────────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadDimDate
    @StartDate    DATE,
    @EndDate      DATE,
    @RowsInserted INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH d AS
    (
        SELECT DATEADD(DAY, n - 1, @StartDate) AS FullDate
        FROM etl.Numbers
        WHERE n <= DATEDIFF(DAY, @StartDate, @EndDate) + 1
    )
    INSERT INTO dim.Date (DateKey, FullDate, DayOfMonth, DayName, IsWeekend, MonthKey, MonthNumber, MonthName,
                          MonthStartDate, MonthEndDate, QuarterNumber, QuarterLabel, CalendarYear, FiscalYear,
                          FiscalQuarter, IsLastDayOfMonth)
    SELECT YEAR(FullDate) * 10000 + MONTH(FullDate) * 100 + DAY(FullDate),
           FullDate,
           DAY(FullDate),
           DATENAME(WEEKDAY, FullDate),
           CASE WHEN DATENAME(WEEKDAY, FullDate) IN ('Friday','Saturday') THEN 1 ELSE 0 END,   -- language-independent alternative: DATEPART with SET DATEFIRST
           YEAR(FullDate) * 100 + MONTH(FullDate),
           MONTH(FullDate),
           DATENAME(MONTH, FullDate),
           DATEFROMPARTS(YEAR(FullDate), MONTH(FullDate), 1),
           EOMONTH(FullDate),
           DATEPART(QUARTER, FullDate),
           CONCAT(YEAR(FullDate), 'Q', DATEPART(QUARTER, FullDate)),
           YEAR(FullDate),
           CASE WHEN MONTH(FullDate) >= 7 THEN YEAR(FullDate) + 1 ELSE YEAR(FullDate) END,
           ((MONTH(FullDate) + 5) % 12) / 3 + 1,
           CASE WHEN FullDate = EOMONTH(FullDate) THEN 1 ELSE 0 END
    FROM d
    WHERE NOT EXISTS (SELECT 1 FROM dim.Date x WHERE x.FullDate = d.FullDate);

    SET @RowsInserted = @@ROWCOUNT;
END
GO

/* ───────────────────────────── 2 · reference dims ───────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadReferenceDims
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT,
    @RowsUpdated  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actions TABLE (MergeAction NVARCHAR(10));

    ;WITH prod AS
    (
        SELECT ProductID, TRIM(ProductCode) AS ProductCode, TRIM(ProductName) AS ProductName, TRIM(ProductType) AS ProductType,
               CASE WHEN IsLiability = 1 THEN 'Deposit' ELSE 'Lending' END AS ProductFamily, IsLiability, AnnualRatePct,
               ROW_NUMBER() OVER (PARTITION BY ProductID ORDER BY ProductID) AS rn
        FROM src.ProductExtract
        WHERE ProductID IS NOT NULL
    )
    MERGE dim.Product AS tgt
    USING (SELECT * FROM prod WHERE rn = 1) AS s ON tgt.ProductID = s.ProductID
    WHEN MATCHED AND EXISTS (SELECT tgt.ProductCode, tgt.ProductName, tgt.ProductType, tgt.IsLiability, tgt.AnnualRatePct
                             EXCEPT
                             SELECT s.ProductCode, s.ProductName, s.ProductType, s.IsLiability, s.AnnualRatePct)
        THEN UPDATE SET ProductCode = s.ProductCode, ProductName = s.ProductName, ProductType = s.ProductType,
                        ProductFamily = s.ProductFamily, IsLiability = s.IsLiability, AnnualRatePct = s.AnnualRatePct
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (ProductID, ProductCode, ProductName, ProductType, ProductFamily, IsLiability, AnnualRatePct)
             VALUES (s.ProductID, s.ProductCode, s.ProductName, s.ProductType, s.ProductFamily, s.IsLiability, s.AnnualRatePct)
    OUTPUT $action INTO @actions;

    ;WITH br AS
    (
        SELECT BranchID, TRIM(BranchCode) AS BranchCode, TRIM(BranchName) AS BranchName, TRIM(City) AS City,
               TRIM(Governorate) AS Governorate, TRIM(Region) AS Region, OpenedYear,
               ROW_NUMBER() OVER (PARTITION BY BranchID ORDER BY BranchID) AS rn
        FROM src.BranchExtract
        WHERE BranchID IS NOT NULL
    )
    MERGE dim.Branch AS tgt
    USING (SELECT * FROM br WHERE rn = 1) AS s ON tgt.BranchID = s.BranchID
    WHEN MATCHED AND EXISTS (SELECT tgt.BranchCode, tgt.BranchName, tgt.City, tgt.Governorate, tgt.Region, tgt.OpenedYear
                             EXCEPT
                             SELECT s.BranchCode, s.BranchName, s.City, s.Governorate, s.Region, s.OpenedYear)
        THEN UPDATE SET BranchCode = s.BranchCode, BranchName = s.BranchName, City = s.City,
                        Governorate = s.Governorate, Region = s.Region, OpenedYear = s.OpenedYear
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (BranchID, BranchCode, BranchName, City, Governorate, Region, OpenedYear)
             VALUES (s.BranchID, s.BranchCode, s.BranchName, s.City, s.Governorate, s.Region, s.OpenedYear)
    OUTPUT $action INTO @actions;

    SELECT @RowsInserted = COUNT(CASE WHEN MergeAction = 'INSERT' THEN 1 END),
           @RowsUpdated  = COUNT(CASE WHEN MergeAction = 'UPDATE' THEN 1 END)
    FROM @actions;
END
GO

/* ───────────────────────────── 3 · stage customers ──────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_StageCustomers
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT,
    @RowsRejected INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE stg.Customer;

    -- reject rows without a business key (payload kept as JSON for triage)
    INSERT INTO stg.Rejected (LoadID, SourceTable, SourceKey, Reason, RowPayload)
    SELECT @LoadID, 'src.CustomerExtract', NULL, 'NULL CustomerID',
           (SELECT c.FirstName, c.LastName, c.Segment, c.City, c.OnboardDate FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM src.CustomerExtract AS c
    WHERE c.CustomerID IS NULL;
    SET @RowsRejected = @@ROWCOUNT;

    INSERT INTO stg.Rejected (LoadID, SourceTable, SourceKey, Reason, RowPayload)
    SELECT @LoadID, 'src.CustomerExtract', CAST(c.CustomerID AS NVARCHAR(50)), 'NULL OnboardDate',
           (SELECT c.CustomerID, c.FirstName, c.LastName FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM src.CustomerExtract AS c
    WHERE c.CustomerID IS NOT NULL AND c.OnboardDate IS NULL;
    SET @RowsRejected += @@ROWCOUNT;

    /* one row per customer = the most recent version in the extract (re-sent files
       and superseded versions are dropped here, not in the dimension) */
    ;WITH latest AS
    (
        SELECT c.*,
               ROW_NUMBER() OVER (PARTITION BY c.CustomerID ORDER BY c.UpdatedAt DESC, c.ExtractedAt DESC) AS rn
        FROM src.CustomerExtract AS c
        WHERE c.CustomerID IS NOT NULL AND c.OnboardDate IS NOT NULL
    ),
    cleansed AS
    (
        SELECT
            l.CustomerID,
            FullName   = CONCAT(TRIM(ISNULL(l.FirstName, N'')), N' ', TRIM(ISNULL(l.LastName, N''))),
            Gender     = CASE UPPER(LEFT(TRIM(ISNULL(l.Gender, '')), 1)) WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END,
            BirthDate  = TRY_CONVERT(DATE, TRIM(l.BirthDate), 23),
            Segment    = COALESCE(NULLIF(TRIM(l.Segment), ''), 'Unknown'),
            -- city: snap dirty variants (case / padding) onto the canonical spelling used by the branch network
            City       = COALESCE(ref.City,
                                  UPPER(LEFT(TRIM(l.City), 1)) + LOWER(SUBSTRING(TRIM(l.City), 2, 59)),
                                  N'Unknown'),
            Governorate      = COALESCE(NULLIF(TRIM(l.Governorate), N''), N'Unknown'),
            EmploymentStatus = COALESCE(NULLIF(TRIM(l.EmploymentStatus), ''), 'Unknown'),
            IncomeBand       = COALESCE(NULLIF(TRIM(l.IncomeBand), ''), 'Unknown'),
            RiskRating       = COALESCE(NULLIF(TRIM(l.RiskRating), ''), 'Unknown'),
            KYCStatus        = COALESCE(NULLIF(TRIM(l.KYCStatus), ''), 'Unknown'),
            l.OnboardDate,
            SourceUpdatedAt  = COALESCE(l.UpdatedAt, CAST(l.OnboardDate AS DATETIME2(0)))
        FROM latest AS l
        OUTER APPLY (SELECT TOP (1) b.City
                     FROM (SELECT DISTINCT TRIM(City) AS City FROM src.BranchExtract WHERE City IS NOT NULL) AS b
                     WHERE LOWER(b.City) = LOWER(TRIM(l.City))) AS ref
        WHERE l.rn = 1
    )
    INSERT INTO stg.Customer (CustomerID, FullName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus,
                              IncomeBand, RiskRating, KYCStatus, OnboardDate, SourceUpdatedAt, RowHash)
    SELECT CustomerID, FullName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus,
           IncomeBand, RiskRating, KYCStatus, OnboardDate, SourceUpdatedAt,
           HASHBYTES('SHA2_256', CONCAT_WS('|', FullName, Gender, ISNULL(CONVERT(CHAR(10), BirthDate, 23), 'NULL'), Segment, City,
                                            Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus,
                                            CONVERT(CHAR(10), OnboardDate, 23)))
    FROM cleansed;
    SET @RowsInserted = @@ROWCOUNT;
END
GO

/* ───────────────────────────── 4 · dim.Customer SCD2 ────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadDimCustomer
    @LoadID        INT,
    @EffectiveDate DATETIME2(0) = NULL,      -- when changed versions take effect (default: now)
    @RowsInserted  INT = NULL OUTPUT,        -- brand-new customers
    @RowsUpdated   INT = NULL OUTPUT         -- customers that received a new version
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @EffectiveDate = ISNULL(@EffectiveDate, SYSUTCDATETIME());

    DECLARE @changes TABLE
    (
        MergeAction NVARCHAR(10), CustomerID INT, FullName NVARCHAR(121), Gender VARCHAR(6), BirthDate DATE,
        Segment VARCHAR(20), City NVARCHAR(60), Governorate NVARCHAR(60), EmploymentStatus VARCHAR(20),
        IncomeBand VARCHAR(20), RiskRating VARCHAR(10), KYCStatus VARCHAR(12), OnboardDate DATE, RowHash BINARY(32)
    );

    BEGIN TRAN;

    /* Step 1 — MERGE current versions against staging.
         • new business key            → insert first version, valid from the beginning of time
         • changed attributes (hash)   → expire the current version
       OUTPUT captures what happened so step 2 can insert the new versions. */
    MERGE dim.Customer AS tgt
    USING stg.Customer AS s
       ON tgt.CustomerID = s.CustomerID AND tgt.IsCurrent = 1
    WHEN MATCHED AND tgt.RowHash <> s.RowHash THEN
        UPDATE SET tgt.IsCurrent = 0,
                   tgt.ValidTo   = @EffectiveDate
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (CustomerID, FullName, Gender, BirthDate, AgeBand, Segment, City, Governorate, EmploymentStatus,
                IncomeBand, RiskRating, KYCStatus, OnboardDate, ValidFrom, ValidTo, IsCurrent, RowHash, LoadID)
        VALUES (s.CustomerID, s.FullName, s.Gender, s.BirthDate,
                CASE WHEN s.BirthDate IS NULL THEN 'Unknown'
                     WHEN DATEDIFF(YEAR, s.BirthDate, @EffectiveDate) < 25 THEN '18-24'
                     WHEN DATEDIFF(YEAR, s.BirthDate, @EffectiveDate) < 35 THEN '25-34'
                     WHEN DATEDIFF(YEAR, s.BirthDate, @EffectiveDate) < 45 THEN '35-44'
                     WHEN DATEDIFF(YEAR, s.BirthDate, @EffectiveDate) < 55 THEN '45-54'
                     WHEN DATEDIFF(YEAR, s.BirthDate, @EffectiveDate) < 65 THEN '55-64'
                     ELSE '65+' END,
                s.Segment, s.City, s.Governorate, s.EmploymentStatus, s.IncomeBand, s.RiskRating, s.KYCStatus,
                s.OnboardDate, '1900-01-01', '9999-12-31', 1, s.RowHash, @LoadID)
    OUTPUT $action, s.CustomerID, s.FullName, s.Gender, s.BirthDate, s.Segment, s.City, s.Governorate,
           s.EmploymentStatus, s.IncomeBand, s.RiskRating, s.KYCStatus, s.OnboardDate, s.RowHash
      INTO @changes;

    /* Step 2 — insert the new versions for the customers we just expired */
    INSERT INTO dim.Customer (CustomerID, FullName, Gender, BirthDate, AgeBand, Segment, City, Governorate, EmploymentStatus,
                              IncomeBand, RiskRating, KYCStatus, OnboardDate, ValidFrom, ValidTo, IsCurrent, RowHash, LoadID)
    SELECT c.CustomerID, c.FullName, c.Gender, c.BirthDate,
           CASE WHEN c.BirthDate IS NULL THEN 'Unknown'
                WHEN DATEDIFF(YEAR, c.BirthDate, @EffectiveDate) < 25 THEN '18-24'
                WHEN DATEDIFF(YEAR, c.BirthDate, @EffectiveDate) < 35 THEN '25-34'
                WHEN DATEDIFF(YEAR, c.BirthDate, @EffectiveDate) < 45 THEN '35-44'
                WHEN DATEDIFF(YEAR, c.BirthDate, @EffectiveDate) < 55 THEN '45-54'
                WHEN DATEDIFF(YEAR, c.BirthDate, @EffectiveDate) < 65 THEN '55-64'
                ELSE '65+' END,
           c.Segment, c.City, c.Governorate, c.EmploymentStatus, c.IncomeBand, c.RiskRating, c.KYCStatus,
           c.OnboardDate, @EffectiveDate, '9999-12-31', 1, c.RowHash, @LoadID
    FROM @changes AS c
    WHERE c.MergeAction = 'UPDATE';
    SET @RowsUpdated = @@ROWCOUNT;

    SELECT @RowsInserted = COUNT(*) FROM @changes WHERE MergeAction = 'INSERT';

    COMMIT;
END
GO

/* ───────────────────────────── 5 · stage accounts ───────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_StageAccounts
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT,
    @RowsRejected INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE stg.Account;

    ;WITH latest AS
    (
        SELECT a.*, ROW_NUMBER() OVER (PARTITION BY a.AccountID ORDER BY a.UpdatedAt DESC) AS rn
        FROM src.AccountExtract AS a
        WHERE a.AccountID IS NOT NULL
    ),
    classified AS
    (
        SELECT l.*,
               Reason = CASE WHEN l.CustomerID IS NULL                                           THEN 'NULL CustomerID'
                             WHEN NOT EXISTS (SELECT 1 FROM stg.Customer c WHERE c.CustomerID = l.CustomerID) THEN 'Orphan: CustomerID not in customer feed'
                             WHEN NOT EXISTS (SELECT 1 FROM dim.Product p WHERE p.ProductID = l.ProductID)    THEN 'Unknown ProductID'
                             WHEN NOT EXISTS (SELECT 1 FROM dim.Branch  b WHERE b.BranchID  = l.BranchID)     THEN 'Unknown BranchID'
                             WHEN l.OpenDate IS NULL                                             THEN 'NULL OpenDate'
                             WHEN l.CloseDate IS NOT NULL AND l.CloseDate < l.OpenDate            THEN 'CloseDate before OpenDate'
                        END
        FROM latest AS l
        WHERE l.rn = 1
    )
    SELECT * INTO #classified FROM classified;

    INSERT INTO stg.Rejected (LoadID, SourceTable, SourceKey, Reason, RowPayload)
    SELECT @LoadID, 'src.AccountExtract', CAST(AccountID AS NVARCHAR(50)), Reason,
           (SELECT AccountID, CustomerID, ProductID, BranchID, OpenDate, Status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM #classified WHERE Reason IS NOT NULL;
    SET @RowsRejected = @@ROWCOUNT;

    INSERT INTO stg.Account (AccountID, CustomerID, ProductID, BranchID, AccountNo, Currency, OpenDate, CloseDate, Status, CreditLimit, SourceUpdatedAt, RowHash)
    SELECT AccountID, CustomerID, ProductID, BranchID,
           TRIM(AccountNo), UPPER(COALESCE(Currency, 'EGP')), OpenDate, CloseDate,
           COALESCE(NULLIF(TRIM(Status), ''), 'Unknown'), CreditLimit,
           COALESCE(UpdatedAt, CAST(OpenDate AS DATETIME2(0))),
           HASHBYTES('SHA2_256', CONCAT_WS('|', CustomerID, ProductID, BranchID, TRIM(AccountNo), UPPER(COALESCE(Currency, 'EGP')),
                                            CONVERT(CHAR(10), OpenDate, 23), ISNULL(CONVERT(CHAR(10), CloseDate, 23), 'NULL'),
                                            TRIM(Status), ISNULL(CAST(CreditLimit AS VARCHAR(20)), 'NULL')))
    FROM #classified WHERE Reason IS NULL;
    SET @RowsInserted = @@ROWCOUNT;

    DROP TABLE #classified;
END
GO

/* ───────────────────────────── 6 · dim.Account SCD1 ─────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadDimAccount
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT,
    @RowsUpdated  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actions TABLE (MergeAction NVARCHAR(10));

    MERGE dim.Account AS tgt
    USING (SELECT s.*, p.ProductKey, b.BranchKey
           FROM stg.Account AS s
           JOIN dim.Product AS p ON p.ProductID = s.ProductID
           JOIN dim.Branch  AS b ON b.BranchID  = s.BranchID) AS s
       ON tgt.AccountID = s.AccountID
    WHEN MATCHED AND tgt.RowHash <> s.RowHash THEN
        UPDATE SET AccountNo = s.AccountNo, CustomerID = s.CustomerID, ProductKey = s.ProductKey, BranchKey = s.BranchKey,
                   Currency = s.Currency, OpenDate = s.OpenDate, CloseDate = s.CloseDate, Status = s.Status,
                   CreditLimit = s.CreditLimit, RowHash = s.RowHash, LoadID = @LoadID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (AccountID, AccountNo, CustomerID, ProductKey, BranchKey, Currency, OpenDate, CloseDate, Status, CreditLimit, RowHash, LoadID)
        VALUES (s.AccountID, s.AccountNo, s.CustomerID, s.ProductKey, s.BranchKey, s.Currency, s.OpenDate, s.CloseDate, s.Status, s.CreditLimit, s.RowHash, @LoadID)
    OUTPUT $action INTO @actions;

    SELECT @RowsInserted = COUNT(CASE WHEN MergeAction = 'INSERT' THEN 1 END),
           @RowsUpdated  = COUNT(CASE WHEN MergeAction = 'UPDATE' THEN 1 END)
    FROM @actions;
END
GO

/* ───────────────────────────── 7 · stage transactions (incremental) ─────── */
CREATE OR ALTER PROCEDURE etl.usp_StageTransactions
    @LoadID        INT,
    @AsOfDate      DATE,                       -- rows dated after this are "future" and rejected
    @RowsInserted  INT = NULL OUTPUT,
    @RowsRejected  INT = NULL OUTPUT,
    @RowsSkipped   INT = NULL OUTPUT           -- already in the fact (re-sent rows) — not an error
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE stg.Transaction;

    DECLARE @Watermark DATETIME2(0) =
        ISNULL((SELECT LastLoadedValue FROM etl.Watermark WHERE TableName = N'fact.Transaction'), '1900-01-01');
    -- one-hour lookback absorbs late-arriving rows; TransactionID uniqueness keeps the load idempotent
    DECLARE @From DATETIME2(0) = DATEADD(HOUR, -1, @Watermark);

    ;WITH extract_rows AS
    (
        SELECT t.*,
               ROW_NUMBER() OVER (PARTITION BY t.TransactionID ORDER BY t.CreatedAt) AS rn
        FROM src.TransactionExtract AS t
        WHERE t.CreatedAt > @From
    ),
    classified AS
    (
        SELECT e.*,
               Reason = CASE WHEN e.TransactionID IS NULL                     THEN 'NULL TransactionID'
                             WHEN e.rn > 1                                    THEN 'Duplicate TransactionID in extract'
                             WHEN e.AccountID IS NULL                         THEN 'NULL AccountID'
                             WHEN e.Amount IS NULL                            THEN 'NULL Amount'
                             WHEN e.TxnDate IS NULL                           THEN 'NULL TxnDate'
                             WHEN e.TxnDate > @AsOfDate                       THEN 'Future-dated transaction'
                             WHEN e.TxnDate > CAST(e.CreatedAt AS DATE)       THEN 'TxnDate after CreatedAt (future-dated)'
                             WHEN e.TxnDate < '2000-01-01'                    THEN 'Implausible TxnDate'
                             WHEN NOT EXISTS (SELECT 1 FROM dim.Account a WHERE a.AccountID = e.AccountID) THEN 'Orphan: unknown AccountID'
                        END,
               AlreadyLoaded = CASE WHEN EXISTS (SELECT 1 FROM fact.Transaction f WHERE f.TransactionID = e.TransactionID) THEN 1 ELSE 0 END
        FROM extract_rows AS e
    )
    SELECT * INTO #classified FROM classified;

    INSERT INTO stg.Rejected (LoadID, SourceTable, SourceKey, Reason, RowPayload)
    SELECT @LoadID, 'src.TransactionExtract', CAST(TransactionID AS NVARCHAR(50)), Reason,
           (SELECT TransactionID, AccountID, TxnDate, TxnType, Amount, CreatedAt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM #classified
    WHERE Reason IS NOT NULL AND Reason <> 'Duplicate TransactionID in extract';   -- exact re-sends are counted, not stored
    SET @RowsRejected = @@ROWCOUNT;
    SELECT @RowsRejected += COUNT(*) FROM #classified WHERE Reason = 'Duplicate TransactionID in extract';

    SELECT @RowsSkipped = COUNT(*) FROM #classified WHERE Reason IS NULL AND AlreadyLoaded = 1;

    INSERT INTO stg.Transaction (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, CreatedAt)
    SELECT TransactionID, AccountID, TxnDate, ISNULL(TxnTime, '00:00:00'),
           COALESCE(NULLIF(TRIM(TxnType), ''), 'Unknown'), COALESCE(NULLIF(TRIM(Channel), ''), 'Unknown'),
           NULLIF(TRIM(MerchantCategory), ''), Amount, CreatedAt
    FROM #classified
    WHERE Reason IS NULL AND AlreadyLoaded = 0;
    SET @RowsInserted = @@ROWCOUNT;

    DROP TABLE #classified;
END
GO

/* ───────────────────────────── 8 · fact.Transaction ─────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadFactTransaction
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    INSERT INTO fact.Transaction (TransactionID, DateKey, TxnTime, AccountKey, CustomerKey, ProductKey, BranchKey,
                                  ChannelKey, TxnTypeKey, MerchantCategory, Amount, IsCredit, LoadID)
    SELECT s.TransactionID,
           YEAR(s.TxnDate) * 10000 + MONTH(s.TxnDate) * 100 + DAY(s.TxnDate),
           s.TxnTime,
           a.AccountKey,
           ISNULL(c.CustomerKey, -1),          -- SCD2 version that was current on the transaction date
           a.ProductKey,
           a.BranchKey,
           ISNULL(ch.ChannelKey, -1),
           ISNULL(tt.TxnTypeKey, -1),
           s.MerchantCategory,
           s.Amount,
           CASE WHEN s.Amount > 0 THEN 1 ELSE 0 END,
           @LoadID
    FROM stg.Transaction AS s
    JOIN dim.Account          AS a  ON a.AccountID = s.AccountID
    LEFT JOIN dim.Customer    AS c  ON c.CustomerID = a.CustomerID
                                   AND CAST(s.TxnDate AS DATETIME2(0)) >= c.ValidFrom
                                   AND CAST(s.TxnDate AS DATETIME2(0)) <  c.ValidTo
    LEFT JOIN dim.Channel         AS ch ON ch.ChannelName = s.Channel
    LEFT JOIN dim.TransactionType AS tt ON tt.TxnType     = s.TxnType;
    SET @RowsInserted = @@ROWCOUNT;

    -- advance the watermark only when something was loaded
    IF @RowsInserted > 0
    BEGIN
        DECLARE @MaxCreated DATETIME2(0) = (SELECT MAX(CreatedAt) FROM stg.Transaction);
        MERGE etl.Watermark AS w
        USING (SELECT N'fact.Transaction' AS TableName, @MaxCreated AS v) AS s ON w.TableName = s.TableName
        WHEN MATCHED AND s.v > w.LastLoadedValue THEN UPDATE SET LastLoadedValue = s.v, LastLoadID = @LoadID, UpdatedAt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (TableName, LastLoadedValue, LastLoadID) VALUES (s.TableName, s.v, @LoadID);
    END

    COMMIT;
END
GO

/* ───────────────────────────── 9 · fact.Complaint ───────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_LoadFactComplaint
    @LoadID       INT,
    @RowsInserted INT = NULL OUTPUT,
    @RowsUpdated  INT = NULL OUTPUT,
    @RowsRejected INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actions TABLE (MergeAction NVARCHAR(10));

    ;WITH latest AS
    (
        SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ComplaintID ORDER BY c.OpenedDate DESC) AS rn
        FROM src.ComplaintExtract AS c
        WHERE c.ComplaintID IS NOT NULL AND c.CustomerID IS NOT NULL AND c.OpenedDate IS NOT NULL
    ),
    resolved AS
    (
        SELECT l.ComplaintID, l.OpenedDate, l.ClosedDate,
               Category = COALESCE(NULLIF(TRIM(l.Category), ''), 'Other'),
               Channel  = COALESCE(NULLIF(TRIM(l.Channel), ''), 'Unknown'),
               Severity = COALESCE(NULLIF(TRIM(l.Severity), ''), 'Low'),
               Status   = COALESCE(NULLIF(TRIM(l.Status), ''), 'Open'),
               CustomerKey = ISNULL(d.CustomerKey, -1)
        FROM latest AS l
        LEFT JOIN dim.Customer AS d ON d.CustomerID = l.CustomerID
                                   AND CAST(l.OpenedDate AS DATETIME2(0)) >= d.ValidFrom
                                   AND CAST(l.OpenedDate AS DATETIME2(0)) <  d.ValidTo
        WHERE l.rn = 1
    )
    MERGE fact.Complaint AS tgt
    USING resolved AS s ON tgt.ComplaintID = s.ComplaintID
    WHEN MATCHED AND (tgt.Status <> s.Status OR ISNULL(tgt.ClosedDateKey, 0) <> ISNULL(YEAR(s.ClosedDate) * 10000 + MONTH(s.ClosedDate) * 100 + DAY(s.ClosedDate), 0)) THEN
        UPDATE SET Status = s.Status,
                   ClosedDateKey  = YEAR(s.ClosedDate) * 10000 + MONTH(s.ClosedDate) * 100 + DAY(s.ClosedDate),
                   ResolutionDays = DATEDIFF(DAY, s.OpenedDate, s.ClosedDate),
                   LoadID = @LoadID
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ComplaintID, CustomerKey, OpenedDateKey, ClosedDateKey, Category, Channel, Severity, Status, ResolutionDays, LoadID)
        VALUES (s.ComplaintID, s.CustomerKey,
                YEAR(s.OpenedDate) * 10000 + MONTH(s.OpenedDate) * 100 + DAY(s.OpenedDate),
                YEAR(s.ClosedDate) * 10000 + MONTH(s.ClosedDate) * 100 + DAY(s.ClosedDate),
                s.Category, s.Channel, s.Severity, s.Status, DATEDIFF(DAY, s.OpenedDate, s.ClosedDate), @LoadID)
    OUTPUT $action INTO @actions;

    SELECT @RowsInserted = COUNT(CASE WHEN MergeAction = 'INSERT' THEN 1 END),
           @RowsUpdated  = COUNT(CASE WHEN MergeAction = 'UPDATE' THEN 1 END)
    FROM @actions;

    SELECT @RowsRejected = COUNT(*) FROM src.ComplaintExtract WHERE ComplaintID IS NULL OR CustomerID IS NULL OR OpenedDate IS NULL;
END
GO

/* ───────────────────────────── 10 · periodic snapshot ───────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_BuildAccountMonthSnapshot
    @LoadID        INT,
    @FromMonthKey  INT,               -- yyyymm inclusive
    @ToMonthKey    INT,               -- yyyymm inclusive
    @RowsInserted  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Month grid: every open account × every month it was open in the range.
       Balances are positions relative to the start of the loaded history
       (the source has no opening balances), which is exactly how a warehouse
       built from a transaction feed works before a balance snapshot is added. */
    ;WITH months AS
    (
        SELECT MonthKey, MIN(FullDate) AS MonthStart, MAX(FullDate) AS MonthEnd
        FROM dim.Date
        WHERE MonthKey BETWEEN @FromMonthKey AND @ToMonthKey
        GROUP BY MonthKey
    ),
    grid AS
    (
        SELECT m.MonthKey, m.MonthStart, m.MonthEnd, a.AccountKey, a.AccountID, a.CustomerID, a.ProductKey,
               IsOpen = CASE WHEN a.OpenDate <= m.MonthEnd AND (a.CloseDate IS NULL OR a.CloseDate >= m.MonthStart) THEN 1 ELSE 0 END
        FROM months AS m
        CROSS JOIN dim.Account AS a
        WHERE a.AccountKey <> -1
          AND a.OpenDate <= m.MonthEnd
    ),
    activity AS
    (
        SELECT f.AccountKey, d.MonthKey,
               TxnCount     = COUNT(*),
               NetAmount    = SUM(f.Amount),
               CreditAmount = SUM(CASE WHEN f.Amount > 0 THEN f.Amount ELSE 0 END),
               DebitAmount  = SUM(CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END),
               FeeAmount    = SUM(CASE WHEN tt.TxnType = 'Fee' THEN -f.Amount ELSE 0 END),
               DigitalTxnCount = SUM(CASE WHEN ch.IsDigital = 1 THEN 1 ELSE 0 END),
               LastTxnDate  = MAX(d.FullDate)
        FROM fact.Transaction AS f
        JOIN dim.Date AS d ON d.DateKey = f.DateKey
        JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
        JOIN dim.Channel AS ch ON ch.ChannelKey = f.ChannelKey
        WHERE d.MonthKey <= @ToMonthKey
        GROUP BY f.AccountKey, d.MonthKey
    ),
    joined AS
    (
        SELECT g.MonthKey, g.MonthEnd, g.AccountKey, g.CustomerID, g.ProductKey, g.IsOpen,
               TxnCount        = ISNULL(act.TxnCount, 0),
               NetAmount       = ISNULL(act.NetAmount, 0),
               CreditAmount    = ISNULL(act.CreditAmount, 0),
               DebitAmount     = ISNULL(act.DebitAmount, 0),
               FeeAmount       = ISNULL(act.FeeAmount, 0),
               DigitalTxnCount = ISNULL(act.DigitalTxnCount, 0),
               LastTxnInMonth  = act.LastTxnDate
        FROM grid AS g
        LEFT JOIN activity AS act ON act.AccountKey = g.AccountKey AND act.MonthKey = g.MonthKey
    ),
    windowed AS
    (
        SELECT j.*,
               ClosingBalance = SUM(j.NetAmount) OVER (PARTITION BY j.AccountKey ORDER BY j.MonthKey ROWS UNBOUNDED PRECEDING),
               LastTxnDate    = MAX(j.LastTxnInMonth) OVER (PARTITION BY j.AccountKey ORDER BY j.MonthKey ROWS UNBOUNDED PRECEDING),
               Txn3M          = SUM(j.TxnCount) OVER (PARTITION BY j.AccountKey ORDER BY j.MonthKey ROWS 2 PRECEDING)
        FROM joined AS j
    )
    SELECT * INTO #snap FROM windowed;

    BEGIN TRAN;

    DELETE FROM fact.AccountMonthSnapshot WHERE MonthKey BETWEEN @FromMonthKey AND @ToMonthKey;

    INSERT INTO fact.AccountMonthSnapshot (MonthKey, AccountKey, CustomerKey, ProductKey, OpeningBalance, ClosingBalance, TxnCount,
                                           CreditAmount, DebitAmount, FeeAmount, DigitalTxnCount, LastTxnDate, DaysSinceLastTxn,
                                           IsDormant3M, IsOpen, LoadID)
    SELECT s.MonthKey, s.AccountKey,
           ISNULL(c.CustomerKey, -1),
           s.ProductKey,
           s.ClosingBalance - s.NetAmount,
           s.ClosingBalance,
           s.TxnCount, s.CreditAmount, s.DebitAmount, s.FeeAmount, s.DigitalTxnCount,
           s.LastTxnDate,
           DATEDIFF(DAY, s.LastTxnDate, s.MonthEnd),
           CASE WHEN s.Txn3M = 0 THEN 1 ELSE 0 END,
           s.IsOpen,
           @LoadID
    FROM #snap AS s
    LEFT JOIN dim.Customer AS c ON c.CustomerID = s.CustomerID
                               AND CAST(s.MonthEnd AS DATETIME2(0)) >= c.ValidFrom
                               AND CAST(s.MonthEnd AS DATETIME2(0)) <  c.ValidTo
    WHERE s.MonthKey BETWEEN @FromMonthKey AND @ToMonthKey;
    SET @RowsInserted = @@ROWCOUNT;

    COMMIT;
    DROP TABLE #snap;
END
GO

/* ───────────────────────────── 11 · rpt.Customer360 ─────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_RefreshCustomer360
    @LoadID        INT,
    @SnapshotDate  DATE,
    @RowsInserted  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SnapshotMonthKey INT  = YEAR(@SnapshotDate) * 100 + MONTH(@SnapshotDate);
    DECLARE @From12M          DATE = DATEADD(MONTH, -12, DATEADD(DAY, 1, @SnapshotDate));
    DECLARE @From12MKey       INT  = YEAR(@From12M) * 10000 + MONTH(@From12M) * 100 + DAY(@From12M);
    DECLARE @SnapshotDateKey  INT  = YEAR(@SnapshotDate) * 10000 + MONTH(@SnapshotDate) * 100 + DAY(@SnapshotDate);

    ;WITH cust AS
    (
        SELECT c.CustomerKey, c.CustomerID, c.FullName, c.Segment, c.Governorate, c.AgeBand, c.IncomeBand, c.OnboardDate,
               TenureMonths = DATEDIFF(MONTH, c.OnboardDate, @SnapshotDate)
        FROM dim.Customer AS c
        WHERE c.IsCurrent = 1 AND c.CustomerKey <> -1
    ),
    holdings AS
    (
        SELECT a.CustomerID,
               ProductsHeld    = COUNT(*),
               HasCurrent      = MAX(CASE WHEN p.ProductType = 'Current'      THEN 1 ELSE 0 END),
               HasSavings      = MAX(CASE WHEN p.ProductType = 'Savings'      THEN 1 ELSE 0 END),
               HasFixedDeposit = MAX(CASE WHEN p.ProductType = 'FixedDeposit' THEN 1 ELSE 0 END),
               HasCreditCard   = MAX(CASE WHEN p.ProductType = 'CreditCard'   THEN 1 ELSE 0 END),
               HasLoan         = MAX(CASE WHEN p.ProductFamily = 'Lending' AND p.ProductType <> 'CreditCard' THEN 1 ELSE 0 END)
        FROM dim.Account AS a
        JOIN dim.Product AS p ON p.ProductKey = a.ProductKey
        WHERE a.IsOpen = 1 AND a.AccountKey <> -1
        GROUP BY a.CustomerID
    ),
    balances AS
    (
        SELECT a.CustomerID,
               TotalDepositBalance = SUM(CASE WHEN p.IsLiability = 1 THEN s.ClosingBalance ELSE 0 END)
        FROM fact.AccountMonthSnapshot AS s
        JOIN dim.Account AS a ON a.AccountKey = s.AccountKey
        JOIN dim.Product AS p ON p.ProductKey = a.ProductKey
        WHERE s.MonthKey = @SnapshotMonthKey
        GROUP BY a.CustomerID
    ),
    activity12 AS
    (
        SELECT a.CustomerID,
               TxnCount12M   = COUNT(*),
               Spend12M      = SUM(CASE WHEN tt.TxnGroup IN ('Spending','Cash') AND f.Amount < 0 THEN -f.Amount ELSE 0 END),
               DigitalTxnPct = 100.0 * SUM(CASE WHEN ch.IsDigital = 1 THEN 1 ELSE 0 END) / COUNT(*),
               LastTxnDateKey = MAX(f.DateKey)
        FROM fact.Transaction AS f
        JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
        JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
        JOIN dim.Channel AS ch ON ch.ChannelKey = f.ChannelKey
        WHERE f.DateKey BETWEEN @From12MKey AND @SnapshotDateKey
        GROUP BY a.CustomerID
    ),
    lasttxn AS
    (
        SELECT a.CustomerID, LastTxnDateKey = MAX(f.DateKey)
        FROM fact.Transaction AS f
        JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
        WHERE f.DateKey <= @SnapshotDateKey
        GROUP BY a.CustomerID
    ),
    complaints AS
    (
        SELECT c.CustomerID,
               ComplaintsLast12M = SUM(CASE WHEN fc.OpenedDateKey BETWEEN @From12MKey AND @SnapshotDateKey THEN 1 ELSE 0 END),
               OpenComplaints    = SUM(CASE WHEN fc.Status IN ('Open','Escalated') THEN 1 ELSE 0 END)
        FROM fact.Complaint AS fc
        JOIN dim.Customer AS c ON c.CustomerKey = fc.CustomerKey
        GROUP BY c.CustomerID
    ),
    base AS
    (
        SELECT cu.*,
               ProductsHeld    = ISNULL(h.ProductsHeld, 0),
               HasCurrent      = ISNULL(h.HasCurrent, 0),      HasSavings = ISNULL(h.HasSavings, 0),
               HasFixedDeposit = ISNULL(h.HasFixedDeposit, 0), HasCreditCard = ISNULL(h.HasCreditCard, 0),
               HasLoan         = ISNULL(h.HasLoan, 0),
               TotalDepositBalance = ISNULL(b.TotalDepositBalance, 0),
               MonthlyTxnAvg   = ISNULL(a12.TxnCount12M, 0) / 12.0,
               MonthlySpendAvg = ISNULL(a12.Spend12M, 0) / 12.0,
               DigitalTxnPct   = a12.DigitalTxnPct,
               LastTxnDate     = TRY_CONVERT(DATE, CAST(lt.LastTxnDateKey AS CHAR(8)), 112),
               DaysSinceLastTxn = DATEDIFF(DAY, TRY_CONVERT(DATE, CAST(lt.LastTxnDateKey AS CHAR(8)), 112), @SnapshotDate),
               ComplaintsLast12M = ISNULL(cp.ComplaintsLast12M, 0),
               OpenComplaints    = ISNULL(cp.OpenComplaints, 0)
        FROM cust AS cu
        LEFT JOIN holdings   AS h   ON h.CustomerID   = cu.CustomerID
        LEFT JOIN balances   AS b   ON b.CustomerID   = cu.CustomerID
        LEFT JOIN activity12 AS a12 ON a12.CustomerID = cu.CustomerID
        LEFT JOIN lasttxn    AS lt  ON lt.CustomerID  = cu.CustomerID
        LEFT JOIN complaints AS cp  ON cp.CustomerID  = cu.CustomerID
    ),
    scored AS
    (
        SELECT b.*,
               -- RFM quintiles: 5 = best.  Customers with no activity at all get the lowest score.
               RecencyScore   = CASE WHEN b.LastTxnDate IS NULL THEN 1 ELSE NTILE(5) OVER (ORDER BY b.DaysSinceLastTxn DESC) END,
               FrequencyScore = NTILE(5) OVER (ORDER BY b.MonthlyTxnAvg ASC),
               MonetaryScore  = NTILE(5) OVER (ORDER BY b.MonthlySpendAvg + b.TotalDepositBalance / 12.0 ASC)
        FROM base AS b
    )
    SELECT * INTO #c360 FROM scored;

    BEGIN TRAN;
    TRUNCATE TABLE rpt.Customer360;

    INSERT INTO rpt.Customer360 (CustomerKey, CustomerID, FullName, Segment, Governorate, AgeBand, IncomeBand, TenureMonths, TenureBand,
                                 ProductsHeld, HasCurrent, HasSavings, HasFixedDeposit, HasCreditCard, HasLoan, TotalDepositBalance,
                                 MonthlyTxnAvg, MonthlySpendAvg, DigitalTxnPct, LastTxnDate, DaysSinceLastTxn, ComplaintsLast12M,
                                 OpenComplaints, RecencyScore, FrequencyScore, MonetaryScore, RFMSegment, IsChurned, ChurnRiskBand,
                                 ChurnRiskReasons, SnapshotDate)
    SELECT s.CustomerKey, s.CustomerID, s.FullName, s.Segment, s.Governorate, s.AgeBand, s.IncomeBand, s.TenureMonths,
           CASE WHEN s.TenureMonths < 12 THEN '<1 yr' WHEN s.TenureMonths < 36 THEN '1-3 yrs' WHEN s.TenureMonths < 72 THEN '3-6 yrs' ELSE '6+ yrs' END,
           s.ProductsHeld, s.HasCurrent, s.HasSavings, s.HasFixedDeposit, s.HasCreditCard, s.HasLoan, s.TotalDepositBalance,
           s.MonthlyTxnAvg, s.MonthlySpendAvg, s.DigitalTxnPct, s.LastTxnDate, s.DaysSinceLastTxn, s.ComplaintsLast12M, s.OpenComplaints,
           s.RecencyScore, s.FrequencyScore, s.MonetaryScore,
           CASE WHEN s.RecencyScore >= 4 AND s.FrequencyScore >= 4 AND s.MonetaryScore >= 4 THEN 'Champions'
                WHEN s.FrequencyScore >= 4 AND s.RecencyScore >= 3                          THEN 'Loyal'
                WHEN s.RecencyScore >= 4 AND s.FrequencyScore <= 3                          THEN 'Potential'
                WHEN s.TenureMonths <= 6                                                    THEN 'New'
                WHEN s.RecencyScore <= 2 AND s.MonetaryScore >= 4                           THEN 'At Risk - high value'
                WHEN s.RecencyScore <= 2 AND s.FrequencyScore >= 3                          THEN 'At Risk'
                WHEN s.RecencyScore <= 2                                                    THEN 'Hibernating'
                ELSE 'Need Attention' END,
           x.IsChurned,
           x.ChurnRiskBand,
           x.ChurnRiskReasons,
           @SnapshotDate
    FROM #c360 AS s
    CROSS APPLY
    (
        SELECT IsChurned = CASE WHEN s.HasLoan = 0 AND (s.LastTxnDate IS NULL AND s.TenureMonths >= 3 OR s.DaysSinceLastTxn >= 90) THEN 1 ELSE 0 END
    ) AS ch
    CROSS APPLY
    (
        SELECT IsChurned = ch.IsChurned,
               ChurnRiskBand = CASE WHEN ch.IsChurned = 1 OR s.DaysSinceLastTxn >= 60 OR (s.ComplaintsLast12M >= 2 AND s.OpenComplaints >= 1) THEN 'High'
                                    WHEN s.DaysSinceLastTxn >= 30 OR s.ComplaintsLast12M >= 1 OR (s.ProductsHeld <= 1 AND ISNULL(s.DigitalTxnPct, 0) < 20) THEN 'Medium'
                                    ELSE 'Low' END,
               ChurnRiskReasons = NULLIF(CONCAT_WS('; ',
                                    CASE WHEN ch.IsChurned = 1 THEN 'no activity 90+ days' END,
                                    CASE WHEN ch.IsChurned = 0 AND s.DaysSinceLastTxn >= 30 THEN CONCAT('inactive ', s.DaysSinceLastTxn, ' days') END,
                                    CASE WHEN s.OpenComplaints >= 1 THEN CONCAT(s.OpenComplaints, ' open complaint(s)') END,
                                    CASE WHEN s.ComplaintsLast12M >= 2 THEN CONCAT(s.ComplaintsLast12M, ' complaints in 12M') END,
                                    CASE WHEN s.ProductsHeld <= 1 THEN 'single product' END,
                                    CASE WHEN ISNULL(s.DigitalTxnPct, 0) < 20 THEN 'low digital adoption' END), '')
    ) AS x;
    SET @RowsInserted = @@ROWCOUNT;

    COMMIT;
    DROP TABLE #c360;
END
GO

/* ───────────────────────────── 12 · data-quality gate ───────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_RunDataQuality
    @LoadID       INT,
    @AsOfDate     DATE,
    @FailOnError  BIT = 1,
    @FailCount    INT = NULL OUTPUT,
    @WarnCount    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @r TABLE (CheckName VARCHAR(80), Severity VARCHAR(5), Observed DECIMAL(18,2), Expected VARCHAR(60), Details NVARCHAR(400), Passed BIT);

    -- 1. SCD2 integrity: exactly one current row per customer
    INSERT INTO @r SELECT 'dim.Customer: one current row per CustomerID', 'FAIL', COUNT(*), '0 violations', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM (SELECT CustomerID FROM dim.Customer WHERE CustomerKey <> -1 GROUP BY CustomerID HAVING SUM(CASE WHEN IsCurrent = 1 THEN 1 ELSE 0 END) <> 1) AS v;

    -- 2. SCD2 integrity: versions must not overlap or leave gaps
    INSERT INTO @r SELECT 'dim.Customer: contiguous validity ranges', 'FAIL', COUNT(*), '0 violations', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM (SELECT CustomerID, ValidFrom, LAG(ValidTo) OVER (PARTITION BY CustomerID ORDER BY ValidFrom) AS PrevValidTo
          FROM dim.Customer WHERE CustomerKey <> -1) AS v
    WHERE v.PrevValidTo IS NOT NULL AND v.PrevValidTo <> v.ValidFrom;

    -- 3. Fact keys resolved
    INSERT INTO @r SELECT 'fact.Transaction: no unresolved CustomerKey (-1)', 'FAIL', COUNT(*), '0 rows', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM fact.Transaction WHERE CustomerKey = -1;

    INSERT INTO @r SELECT 'fact.Transaction: no unresolved Channel/TxnType (-1)', 'WARN', COUNT(*), '0 rows', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM fact.Transaction WHERE ChannelKey = -1 OR TxnTypeKey = -1;

    -- 4. Reconciliation against the source: every valid, non-duplicate, non-future source row is in the fact, once
    ;WITH valid_src AS
    (
        SELECT t.TransactionID, MIN(t.Amount) AS Amount
        FROM src.TransactionExtract AS t
        WHERE t.TransactionID IS NOT NULL AND t.AccountID IS NOT NULL AND t.Amount IS NOT NULL
          AND t.TxnDate IS NOT NULL AND t.TxnDate <= @AsOfDate AND t.TxnDate >= '2000-01-01'
          AND t.TxnDate <= CAST(t.CreatedAt AS DATE)
          AND EXISTS (SELECT 1 FROM dim.Account a WHERE a.AccountID = t.AccountID)
        GROUP BY t.TransactionID
    ),
    totals AS
    (
        SELECT (SELECT COUNT(*) FROM valid_src) AS SrcRows, (SELECT SUM(Amount) FROM valid_src) AS SrcAmount,
               (SELECT COUNT(*) FROM fact.Transaction) AS FactRows, (SELECT SUM(Amount) FROM fact.Transaction) AS FactAmount
    )
    INSERT INTO @r
    SELECT 'Reconciliation: fact row count = valid source rows', 'FAIL', FactRows, CAST(SrcRows AS VARCHAR(20)),
           CONCAT('source ', SrcRows, ' vs fact ', FactRows), CASE WHEN FactRows = SrcRows THEN 1 ELSE 0 END FROM totals
    UNION ALL
    SELECT 'Reconciliation: fact amount total = valid source total', 'FAIL', FactAmount, CAST(SrcAmount AS VARCHAR(30)),
           CONCAT('difference ', ABS(ISNULL(FactAmount, 0) - ISNULL(SrcAmount, 0))), CASE WHEN ABS(ISNULL(FactAmount, 0) - ISNULL(SrcAmount, 0)) < 0.01 THEN 1 ELSE 0 END FROM totals;

    -- 5. No future-dated facts, no dates outside dim.Date
    INSERT INTO @r SELECT 'fact.Transaction: no future-dated rows', 'FAIL', COUNT(*), '0 rows', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM fact.Transaction WHERE DateKey > YEAR(@AsOfDate) * 10000 + MONTH(@AsOfDate) * 100 + DAY(@AsOfDate);

    INSERT INTO @r SELECT 'fact.Transaction: every DateKey exists in dim.Date', 'FAIL', COUNT(*), '0 rows', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM fact.Transaction f WHERE NOT EXISTS (SELECT 1 FROM dim.Date d WHERE d.DateKey = f.DateKey);

    -- 6. Snapshot integrity: last closing balance per account equals the sum of its transactions
    INSERT INTO @r SELECT 'Snapshot: closing balance = cumulative transactions', 'FAIL', COUNT(*), '0 accounts off', NULL, CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
    FROM (SELECT s.AccountKey, s.ClosingBalance, ISNULL(t.Total, 0) AS Total
          FROM fact.AccountMonthSnapshot AS s
          JOIN (SELECT AccountKey, MAX(MonthKey) AS MaxMonth FROM fact.AccountMonthSnapshot GROUP BY AccountKey) AS lastm
                ON lastm.AccountKey = s.AccountKey AND lastm.MaxMonth = s.MonthKey
          LEFT JOIN (SELECT AccountKey, SUM(Amount) AS Total FROM fact.Transaction GROUP BY AccountKey) AS t ON t.AccountKey = s.AccountKey) AS v
    WHERE ABS(v.ClosingBalance - v.Total) >= 0.01;

    -- 7. Serving layer complete
    INSERT INTO @r SELECT 'rpt.Customer360: one row per current customer', 'FAIL',
           (SELECT COUNT(*) FROM rpt.Customer360), CAST((SELECT COUNT(*) FROM dim.Customer WHERE IsCurrent = 1 AND CustomerKey <> -1) AS VARCHAR(20)), NULL,
           CASE WHEN (SELECT COUNT(*) FROM rpt.Customer360) = (SELECT COUNT(*) FROM dim.Customer WHERE IsCurrent = 1 AND CustomerKey <> -1) THEN 1 ELSE 0 END;

    -- 8. Soft checks
    INSERT INTO @r SELECT 'Rejected rows this load', 'WARN', COUNT(*), '< 1% of extract',
           (SELECT STRING_AGG(CONCAT(Reason, '=', cnt), ', ') FROM (SELECT Reason, COUNT(*) AS cnt FROM stg.Rejected WHERE LoadID = @LoadID GROUP BY Reason) AS x),
           CASE WHEN COUNT(*) <= 0.01 * (SELECT COUNT(*) FROM src.TransactionExtract) THEN 1 ELSE 0 END
    FROM stg.Rejected WHERE LoadID = @LoadID;

    INSERT INTO @r SELECT 'Customers without an open account', 'WARN', COUNT(*), 'informational', NULL, 1
    FROM dim.Customer c WHERE c.IsCurrent = 1 AND c.CustomerKey <> -1
      AND NOT EXISTS (SELECT 1 FROM dim.Account a WHERE a.CustomerID = c.CustomerID AND a.IsOpen = 1);

    INSERT INTO @r SELECT 'Deposit accounts with negative position at latest month', 'WARN', COUNT(*), 'informational', NULL, 1
    FROM fact.AccountMonthSnapshot s
    JOIN dim.Product p ON p.ProductKey = s.ProductKey
    WHERE p.IsLiability = 1 AND s.ClosingBalance < 0 AND s.MonthKey = (SELECT MAX(MonthKey) FROM fact.AccountMonthSnapshot);

    INSERT INTO @r SELECT 'Complaints open for more than 30 days', 'INFO', COUNT(*), 'informational', NULL, 1
    FROM fact.Complaint fc JOIN dim.Date d ON d.DateKey = fc.OpenedDateKey
    WHERE fc.Status IN ('Open','Escalated') AND DATEDIFF(DAY, d.FullDate, @AsOfDate) > 30;

    -- persist
    INSERT INTO audit.DataQualityResult (LoadID, CheckName, Severity, Status, Observed, Expected, Details)
    SELECT @LoadID, CheckName, Severity,
           CASE WHEN Passed = 1 THEN 'PASS' WHEN Severity = 'FAIL' THEN 'FAIL' ELSE 'WARN' END,
           Observed, Expected, Details
    FROM @r;

    SELECT @FailCount = COUNT(CASE WHEN Passed = 0 AND Severity = 'FAIL' THEN 1 END),
           @WarnCount = COUNT(CASE WHEN Passed = 0 AND Severity <> 'FAIL' THEN 1 END)
    FROM @r;

    IF @FailOnError = 1 AND @FailCount > 0
    BEGIN
        DECLARE @msg NVARCHAR(2000) = CONCAT('Data-quality gate FAILED (', @FailCount, '): ',
            (SELECT STRING_AGG(CheckName, '; ') FROM @r WHERE Passed = 0 AND Severity = 'FAIL'));
        THROW 50001, @msg, 1;
    END
END
GO

/* ───────────────────────────── orchestration ────────────────────────────── */
CREATE OR ALTER PROCEDURE etl.usp_RunFullLoad
    @Mode           VARCHAR(12)  = 'Incremental',   -- 'Full' rebuilds facts + snapshot from scratch; 'Incremental' loads new source rows
    @AsOfDate       DATE         = NULL,            -- business date of the load (default: max TxnDate in the extract)
    @EffectiveDate  DATETIME2(0) = NULL,            -- SCD2 effective timestamp for changed customers (default: now)
    @FailOnDQ       BIT          = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoadID INT = NEXT VALUE FOR etl.LoadSeq;
    DECLARE @LogID INT, @ins INT, @upd INT, @rej INT, @skp INT, @fail INT, @warn INT;
    DECLARE @Step SYSNAME;

    IF @AsOfDate IS NULL   -- the extract's own clock: the latest CreatedAt in the landing table
        SELECT @AsOfDate = ISNULL(MAX(CAST(CreatedAt AS DATE)), CAST(SYSUTCDATETIME() AS DATE))
        FROM src.TransactionExtract;

    PRINT CONCAT('=== Load #', @LoadID, ' | mode=', @Mode, ' | as of ', CONVERT(CHAR(10), @AsOfDate, 23), ' ===');

    BEGIN TRY
        IF @Mode = 'Full'
        BEGIN
            SET @Step = 'Reset facts (Full mode)';
            EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
            TRUNCATE TABLE fact.Transaction;
            TRUNCATE TABLE fact.AccountMonthSnapshot;
            DELETE FROM etl.Watermark WHERE TableName = N'fact.Transaction';
            EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @LogID = @LogID;
        END

        SET @Step = 'usp_LoadDimDate';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadDimDate '2015-01-01', '2027-12-31', @RowsInserted = @ins OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @LogID = @LogID;

        SET @Step = 'usp_LoadReferenceDims';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadReferenceDims @LoadID, @RowsInserted = @ins OUTPUT, @RowsUpdated = @upd OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsUpdated = @upd, @LogID = @LogID;

        SET @Step = 'usp_StageCustomers';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_StageCustomers @LoadID, @RowsInserted = @ins OUTPUT, @RowsRejected = @rej OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsRejected = @rej, @LogID = @LogID;

        SET @Step = 'usp_LoadDimCustomer';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadDimCustomer @LoadID, @EffectiveDate, @RowsInserted = @ins OUTPUT, @RowsUpdated = @upd OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsUpdated = @upd, @LogID = @LogID;

        SET @Step = 'usp_StageAccounts';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_StageAccounts @LoadID, @RowsInserted = @ins OUTPUT, @RowsRejected = @rej OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsRejected = @rej, @LogID = @LogID;

        SET @Step = 'usp_LoadDimAccount';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadDimAccount @LoadID, @RowsInserted = @ins OUTPUT, @RowsUpdated = @upd OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsUpdated = @upd, @LogID = @LogID;

        SET @Step = 'usp_StageTransactions';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_StageTransactions @LoadID, @AsOfDate, @RowsInserted = @ins OUTPUT, @RowsRejected = @rej OUTPUT, @RowsSkipped = @skp OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsRejected = @rej, @RowsUpdated = @skp, @LogID = @LogID;

        SET @Step = 'usp_LoadFactTransaction';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadFactTransaction @LoadID, @RowsInserted = @ins OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @LogID = @LogID;

        SET @Step = 'usp_LoadFactComplaint';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_LoadFactComplaint @LoadID, @RowsInserted = @ins OUTPUT, @RowsUpdated = @upd OUTPUT, @RowsRejected = @rej OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @RowsUpdated = @upd, @RowsRejected = @rej, @LogID = @LogID;

        SET @Step = 'usp_BuildAccountMonthSnapshot';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        DECLARE @FromMonth INT = (SELECT MIN(DateKey) / 100 FROM fact.Transaction);
        DECLARE @ToMonth   INT = YEAR(@AsOfDate) * 100 + MONTH(@AsOfDate);
        IF @FromMonth IS NOT NULL
            EXEC etl.usp_BuildAccountMonthSnapshot @LoadID, @FromMonth, @ToMonth, @RowsInserted = @ins OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @LogID = @LogID;

        SET @Step = 'usp_RefreshCustomer360';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_RefreshCustomer360 @LoadID, @AsOfDate, @RowsInserted = @ins OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsInserted = @ins, @LogID = @LogID;

        SET @Step = 'usp_RunDataQuality';
        EXEC etl.usp_LogStep @LoadID, @Step, 'Running', @LogID = @LogID OUTPUT;
        EXEC etl.usp_RunDataQuality @LoadID, @AsOfDate, @FailOnDQ, @FailCount = @fail OUTPUT, @WarnCount = @warn OUTPUT;
        EXEC etl.usp_LogStep @LoadID, @Step, 'Succeeded', @RowsRejected = @fail, @RowsUpdated = @warn, @LogID = @LogID;

        PRINT CONCAT('=== Load #', @LoadID, ' succeeded. DQ: ', @fail, ' FAIL, ', @warn, ' WARN ===');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        DECLARE @err NVARCHAR(2000) = CONCAT(ERROR_PROCEDURE(), ' (line ', ERROR_LINE(), '): ', ERROR_MESSAGE());
        EXEC etl.usp_LogStep @LoadID, @Step, 'Failed', @ErrorMessage = @err, @LogID = @LogID;
        PRINT CONCAT('=== Load #', @LoadID, ' FAILED at ', @Step, ': ', @err);
        THROW;
    END CATCH

    -- run summary for the caller
    SELECT LoadID, StepName, Status, RowsInserted, RowsUpdated, RowsRejected,
           DurationSec = DATEDIFF(SECOND, StartedAt, EndedAt), ErrorMessage
    FROM etl.LoadLog WHERE LoadID = @LoadID ORDER BY LogID;
END
GO

PRINT '04_etl_procedures.sql completed: 13 procedures in schema etl.';
GO
