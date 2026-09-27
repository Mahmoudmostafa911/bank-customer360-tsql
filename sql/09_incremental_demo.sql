/* =============================================================================
   09 · Day-2 demo: incremental load, SCD2 history, idempotency
   -----------------------------------------------------------------------------
   Simulates the next business day's extract landing on top of the initial load:
     • 3,000 new transactions dated 2026-01-01/02
     • 300 customers change segment / address        → SCD2 new versions
     • 50 accounts are closed                          → SCD1 update
     • 120 new complaints
     • 200 already-loaded transactions are re-sent     → must be skipped, not duplicated
   Then runs the incremental load twice and shows the evidence.
   Prerequisite: scripts 00–05 executed and etl.usp_RunFullLoad @Mode='Full' run once.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

DECLARE @Day2         DATE         = '2026-01-02';
DECLARE @Day2Created  DATETIME2(0) = '2026-01-02 06:00:00';

DECLARE @FactBefore BIGINT = (SELECT COUNT(*) FROM fact.[Transaction]);
DECLARE @DimBefore  INT    = (SELECT COUNT(*) FROM dim.Customer);
PRINT CONCAT('Before day 2: fact.[Transaction] = ', @FactBefore, ' rows, dim.Customer = ', @DimBefore, ' rows');

/* 1. new transactions ------------------------------------------------------- */
IF OBJECT_ID('tempdb..#ActiveAcct') IS NOT NULL DROP TABLE #ActiveAcct;
SELECT Idx = ROW_NUMBER() OVER (ORDER BY a.AccountID), a.AccountID, p.ProductType
INTO #ActiveAcct
FROM src.AccountExtract AS a
JOIN src.ProductExtract AS p ON p.ProductID = a.ProductID
WHERE a.Status = 'Active' AND a.AccountID < 900000 AND p.ProductType IN ('Current','Savings','CreditCard');
DECLARE @cnt INT = (SELECT COUNT(*) FROM #ActiveAcct);

INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 2000000000 + num.n,
       aa.AccountID,
       DATEADD(DAY, CASE WHEN rD.v < 0.5 THEN 0 ELSE 1 END, CAST('2026-01-01' AS DATE)),
       TIMEFROMPARTS(8 + CAST(FLOOR(rH.v * 13) AS INT), CAST(FLOOR(rM.v * 60) AS INT), 0, 0, 0),
       t.TxnType,
       CASE t.TxnType WHEN 'CardPurchase' THEN 'POS' WHEN 'ATMWithdrawal' THEN 'ATM' WHEN 'Deposit' THEN 'Branch' ELSE 'Mobile' END,
       CASE WHEN t.TxnType = 'CardPurchase' THEN CASE WHEN rC.v < 0.4 THEN 'Groceries' WHEN rC.v < 0.7 THEN 'Restaurants' ELSE 'Fuel' END END,
       CASE t.TxnType WHEN 'CardPurchase' THEN -ROUND(50 + 1950 * POWER(rA.v, 2), 2)
                      WHEN 'ATMWithdrawal' THEN -100 * (2 + CAST(FLOOR(rA.v * 30) AS INT))
                      WHEN 'TransferOut' THEN -ROUND(200 + 19800 * POWER(rA.v, 3), 2)
                      WHEN 'Deposit' THEN ROUND(500 + 19500 * POWER(rA.v, 2), 2)
                      ELSE ROUND(200 + 9800 * POWER(rA.v, 2), 2) END,
       N'Day-2 activity',
       DATEADD(MINUTE, num.n % 300, @Day2Created)
FROM (SELECT n FROM etl.Numbers WHERE n <= 3000) AS num
CROSS APPLY etl.fn_Rnd('day2_acct', num.n) AS rAcc
JOIN #ActiveAcct AS aa ON aa.Idx = CAST(1 + FLOOR(rAcc.v * @cnt) AS BIGINT)
CROSS APPLY etl.fn_Rnd('day2_date', num.n) AS rD
CROSS APPLY etl.fn_Rnd('day2_hour', num.n) AS rH
CROSS APPLY etl.fn_Rnd('day2_min',  num.n) AS rM
CROSS APPLY etl.fn_Rnd('day2_type', num.n) AS rT
CROSS APPLY etl.fn_Rnd('day2_cat',  num.n) AS rC
CROSS APPLY etl.fn_Rnd('day2_amt',  num.n) AS rA
CROSS APPLY (SELECT TxnType = CASE WHEN aa.ProductType = 'CreditCard' THEN 'CardPurchase'
                                   WHEN rT.v < 0.35 THEN 'CardPurchase' WHEN rT.v < 0.55 THEN 'ATMWithdrawal'
                                   WHEN rT.v < 0.75 THEN 'TransferOut'  WHEN rT.v < 0.90 THEN 'Deposit' ELSE 'TransferIn' END) AS t;
PRINT CONCAT('new transactions landed: ', @@ROWCOUNT);

/* 2. customer changes: 300 customers upgrade segment and/or move ------------- */
INSERT INTO src.CustomerExtract (CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus,
                                 IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt)
SELECT TOP (300)
       c.CustomerID, c.FirstName, c.LastName, c.Gender, c.BirthDate,
       CASE WHEN c.Segment = 'Retail' AND c.CustomerID % 3 = 0 THEN 'Affluent' ELSE c.Segment END,
       CASE WHEN c.CustomerID % 3 <> 0 THEN N'New Cairo' ELSE c.City END,
       CASE WHEN c.CustomerID % 3 <> 0 THEN N'Cairo'     ELSE c.Governorate END,
       c.EmploymentStatus,
       CASE WHEN c.Segment = 'Retail' AND c.CustomerID % 3 = 0 THEN '30-60k' ELSE c.IncomeBand END,
       c.RiskRating, 'Verified', c.OnboardDate, @Day2Created
FROM src.CustomerExtract AS c
WHERE c.CustomerID IS NOT NULL AND c.CustomerID % 67 = 1
ORDER BY c.CustomerID;
PRINT CONCAT('customer change records landed: ', @@ROWCOUNT);

/* 3. account closures ------------------------------------------------------- */
UPDATE TOP (50) a
   SET Status = 'Closed', CloseDate = @Day2, UpdatedAt = @Day2Created
FROM src.AccountExtract AS a
WHERE a.Status = 'Active' AND a.AccountID % 640 = 3 AND a.AccountID < 900000;
PRINT CONCAT('accounts closed: ', @@ROWCOUNT);

/* 4. new complaints ---------------------------------------------------------- */
INSERT INTO src.ComplaintExtract (ComplaintID, CustomerID, OpenedDate, ClosedDate, Category, Channel, Severity, Status)
SELECT 6000000 + num.n, c.CustomerID, @Day2, NULL,
       CASE WHEN r.v < 0.5 THEN 'AppOutage' ELSE 'Fees' END, 'Mobile', 'Medium', 'Open'
FROM (SELECT n FROM etl.Numbers WHERE n <= 120) AS num
CROSS APPLY etl.fn_Rnd('day2_cmp', num.n) AS r
CROSS APPLY (SELECT TOP (1) CustomerID FROM stg.Customer WHERE CustomerID % 167 = num.n % 167 ORDER BY CustomerID) AS c;
PRINT CONCAT('complaints landed: ', @@ROWCOUNT);

/* 5. re-sent rows: same TransactionID, new extract timestamp ------------------ */
INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT TOP (200) TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, DATEADD(MINUTE, 30, @Day2Created)
FROM src.TransactionExtract
WHERE TransactionID BETWEEN 1000000000 AND 1000001000
ORDER BY TransactionID;
PRINT CONCAT('re-sent transactions landed: ', @@ROWCOUNT);
GO

/* ---- run the incremental load ----------------------------------------------- */
EXEC etl.usp_RunFullLoad @Mode = 'Incremental', @AsOfDate = '2026-01-02', @EffectiveDate = '2026-01-02 06:00:00';
GO

/* ---- evidence ----------------------------------------------------------------- */
PRINT '--- watermark advanced to the newest CreatedAt ---';
SELECT * FROM etl.Watermark;

PRINT '--- new fact rows are only the day-2 transactions ---';
SELECT d.FullDate, COUNT(*) AS Txns, SUM(f.Amount) AS Net
FROM fact.[Transaction] AS f JOIN dim.Date AS d ON d.DateKey = f.DateKey
WHERE d.FullDate >= '2026-01-01'
GROUP BY d.FullDate ORDER BY d.FullDate;

PRINT '--- SCD2: changed customers now have two versions, facts before the change still point at the old one ---';
SELECT TOP (12) h.CustomerID, h.VersionNo, h.ValidFrom, h.ValidTo, h.IsCurrent, h.PrevSegment, h.Segment, h.PrevCity, h.City
FROM rpt.vw_CustomerHistory AS h
WHERE h.CustomerID IN (SELECT CustomerID FROM dim.Customer GROUP BY CustomerID HAVING COUNT(*) > 1)
ORDER BY h.CustomerID, h.VersionNo;

SELECT CustomersWithHistory = COUNT(*)
FROM (SELECT CustomerID FROM dim.Customer WHERE CustomerKey <> -1 GROUP BY CustomerID HAVING COUNT(*) > 1) AS x;

PRINT '--- closed accounts picked up by the SCD1 merge ---';
SELECT COUNT(*) AS ClosedOnDay2 FROM dim.Account WHERE CloseDate = '2026-01-02';

PRINT '--- what the staging layer did with the re-sent and defective rows ---';
SELECT l.StepName, l.RowsInserted, l.RowsUpdated AS RowsSkippedAlreadyLoaded, l.RowsRejected, l.Status
FROM etl.LoadLog AS l
WHERE l.LoadID = (SELECT MAX(LoadID) FROM etl.LoadLog)
ORDER BY l.LogID;

PRINT '--- data-quality gate for this load ---';
SELECT CheckName, Severity, Status, Observed, Expected FROM rpt.vw_DataQualityLatest ORDER BY Status DESC, CheckName;
GO

/* ---- run it AGAIN: nothing new should be loaded ------------------------------- */
DECLARE @FactBefore BIGINT = (SELECT COUNT(*) FROM fact.[Transaction]);
DECLARE @DimBefore  INT    = (SELECT COUNT(*) FROM dim.Customer);
EXEC etl.usp_RunFullLoad @Mode = 'Incremental', @AsOfDate = '2026-01-02', @EffectiveDate = '2026-01-02 07:00:00';
SELECT FactRowsBefore = @FactBefore, FactRowsAfter = (SELECT COUNT(*) FROM fact.[Transaction]),
       DimCustomerBefore = @DimBefore, DimCustomerAfter = (SELECT COUNT(*) FROM dim.Customer),
       Verdict = CASE WHEN @FactBefore = (SELECT COUNT(*) FROM fact.[Transaction]) AND @DimBefore = (SELECT COUNT(*) FROM dim.Customer)
                      THEN 'idempotent: second run changed nothing' ELSE 'UNEXPECTED: counts changed' END;
GO

PRINT '09_incremental_demo.sql completed.';
GO
