/* =============================================================================
   05 · Serving views (schema rpt) — thin, documented, Power-BI friendly
   -----------------------------------------------------------------------------
   Views keep business logic in one place: SSMS, Excel and Power BI all see the
   same numbers.  No ORDER BY inside views (not allowed without TOP); sort in
   the consumer.
   ============================================================================= */
USE BankDW;
GO

/* Flattened transaction detail — the "one wide table" analysts ask for. */
CREATE OR ALTER VIEW rpt.vw_TransactionDetail
AS
SELECT f.TransactionKey, f.TransactionID,
       d.FullDate AS TxnDate, d.MonthKey, d.CalendarYear, d.MonthName, d.IsWeekend, f.TxnTime,
       c.CustomerID, c.FullName, c.Segment, c.Governorate AS CustomerGovernorate, c.AgeBand, c.IncomeBand,
       a.AccountID, a.AccountNo, p.ProductType, p.ProductFamily,
       b.BranchName, b.Region AS BranchRegion,
       ch.ChannelName, ch.ChannelGroup, ch.IsDigital,
       tt.TxnType, tt.TxnGroup, tt.Direction,
       f.MerchantCategory,
       f.Amount,
       CreditAmount = CASE WHEN f.Amount > 0 THEN  f.Amount ELSE 0 END,
       DebitAmount  = CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END
FROM fact.[Transaction] AS f
JOIN dim.Date            AS d  ON d.DateKey     = f.DateKey
JOIN dim.Customer        AS c  ON c.CustomerKey = f.CustomerKey
JOIN dim.Account         AS a  ON a.AccountKey  = f.AccountKey
JOIN dim.Product         AS p  ON p.ProductKey  = f.ProductKey
JOIN dim.Branch          AS b  ON b.BranchKey   = f.BranchKey
JOIN dim.Channel         AS ch ON ch.ChannelKey = f.ChannelKey
JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey;
GO

/* Monthly KPI strip for the executive page. */
CREATE OR ALTER VIEW rpt.vw_MonthlyKPIs
AS
WITH tx AS
(
    SELECT d.MonthKey,
           ActiveCustomers  = COUNT(DISTINCT a.CustomerID),
           TxnCount         = COUNT(*),
           CreditVolume     = SUM(CASE WHEN f.Amount > 0 THEN f.Amount ELSE 0 END),
           DebitVolume      = SUM(CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END),
           FeeIncome        = SUM(CASE WHEN tt.TxnType = 'Fee' THEN -f.Amount ELSE 0 END),
           DigitalTxnPct    = 100.0 * SUM(CASE WHEN ch.IsDigital = 1 THEN 1 ELSE 0 END) / COUNT(*),
           CardSpend        = SUM(CASE WHEN tt.TxnType = 'CardPurchase' THEN -f.Amount ELSE 0 END)
    FROM fact.[Transaction] AS f
    JOIN dim.Date AS d ON d.DateKey = f.DateKey
    JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
    JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
    JOIN dim.Channel AS ch ON ch.ChannelKey = f.ChannelKey
    GROUP BY d.MonthKey
),
snap AS
(
    SELECT s.MonthKey,
           OpenAccounts     = SUM(CASE WHEN s.IsOpen = 1 THEN 1 ELSE 0 END),
           DormantAccounts  = SUM(CASE WHEN s.IsOpen = 1 AND s.IsDormant3M = 1 THEN 1 ELSE 0 END),
           DepositBalances  = SUM(CASE WHEN p.IsLiability = 1 THEN s.ClosingBalance ELSE 0 END)
    FROM fact.AccountMonthSnapshot AS s
    JOIN dim.Product AS p ON p.ProductKey = s.ProductKey
    GROUP BY s.MonthKey
),
onboard AS
(
    SELECT YEAR(OnboardDate) * 100 + MONTH(OnboardDate) AS MonthKey, COUNT(*) AS NewCustomers
    FROM dim.Customer WHERE IsCurrent = 1 AND CustomerKey <> -1
    GROUP BY YEAR(OnboardDate) * 100 + MONTH(OnboardDate)
),
cmp AS
(
    SELECT d.MonthKey, COUNT(*) AS ComplaintsOpened
    FROM fact.Complaint AS fc JOIN dim.Date AS d ON d.DateKey = fc.OpenedDateKey
    GROUP BY d.MonthKey
)
SELECT m.MonthKey, m.MonthStartDate, m.QuarterLabel, m.FiscalYear,
       tx.ActiveCustomers, tx.TxnCount, tx.CreditVolume, tx.DebitVolume, tx.FeeIncome, tx.CardSpend, tx.DigitalTxnPct,
       snap.OpenAccounts, snap.DormantAccounts,
       DormancyRatePct = 100.0 * snap.DormantAccounts / NULLIF(snap.OpenAccounts, 0),
       snap.DepositBalances,
       NewCustomers = ISNULL(onboard.NewCustomers, 0),
       ComplaintsOpened = ISNULL(cmp.ComplaintsOpened, 0)
FROM (SELECT DISTINCT MonthKey, MonthStartDate, QuarterLabel, FiscalYear FROM dim.Date) AS m
JOIN tx ON tx.MonthKey = m.MonthKey
LEFT JOIN snap    ON snap.MonthKey    = m.MonthKey
LEFT JOIN onboard ON onboard.MonthKey = m.MonthKey
LEFT JOIN cmp     ON cmp.MonthKey     = m.MonthKey;
GO

/* Churn & risk by any customer attribute — slice this in Power BI. */
CREATE OR ALTER VIEW rpt.vw_ChurnBySegment
AS
SELECT Segment, Governorate, AgeBand, IncomeBand, TenureBand, RFMSegment, ChurnRiskBand,
       Customers        = COUNT(*),
       ChurnedCustomers = SUM(CASE WHEN IsChurned = 1 THEN 1 ELSE 0 END),
       ChurnRatePct     = 100.0 * SUM(CASE WHEN IsChurned = 1 THEN 1 ELSE 0 END) / COUNT(*),
       AvgProductsHeld  = AVG(CAST(ProductsHeld AS DECIMAL(5,2))),
       DepositBalances  = SUM(TotalDepositBalance),
       AvgDigitalPct    = AVG(DigitalTxnPct)
FROM rpt.Customer360
GROUP BY Segment, Governorate, AgeBand, IncomeBand, TenureBand, RFMSegment, ChurnRiskBand;
GO

/* Product penetration: which products each segment holds. */
CREATE OR ALTER VIEW rpt.vw_ProductPenetration
AS
SELECT c.Segment, p.ProductType, p.ProductFamily,
       CustomersHolding   = COUNT(DISTINCT a.CustomerID),
       SegmentCustomers   = (SELECT COUNT(*) FROM rpt.Customer360 x WHERE x.Segment = c.Segment),
       PenetrationPct     = 100.0 * COUNT(DISTINCT a.CustomerID) / NULLIF((SELECT COUNT(*) FROM rpt.Customer360 x WHERE x.Segment = c.Segment), 0)
FROM dim.Account AS a
JOIN dim.Product AS p ON p.ProductKey = a.ProductKey
JOIN rpt.Customer360 AS c ON c.CustomerID = a.CustomerID
WHERE a.IsOpen = 1
GROUP BY c.Segment, p.ProductType, p.ProductFamily;
GO

/* Branch league table inputs. */
CREATE OR ALTER VIEW rpt.vw_BranchPerformance
AS
SELECT b.BranchKey, b.BranchName, b.City, b.Governorate, b.Region,
       Accounts        = COUNT(DISTINCT a.AccountKey),
       Customers       = COUNT(DISTINCT a.CustomerID),
       TxnCount        = COUNT(f.TransactionKey),
       FeeIncome       = SUM(CASE WHEN tt.TxnType = 'Fee' THEN -f.Amount ELSE 0 END),
       BranchChannelTxnPct = 100.0 * SUM(CASE WHEN ch.ChannelName = 'Branch' THEN 1 ELSE 0 END) / NULLIF(COUNT(f.TransactionKey), 0),
       DormantAccounts = (SELECT COUNT(*) FROM fact.AccountMonthSnapshot s
                          JOIN dim.Account a2 ON a2.AccountKey = s.AccountKey
                          WHERE a2.BranchKey = b.BranchKey AND s.IsDormant3M = 1 AND s.IsOpen = 1
                            AND s.MonthKey = (SELECT MAX(MonthKey) FROM fact.AccountMonthSnapshot))
FROM dim.Branch AS b
LEFT JOIN dim.Account AS a ON a.BranchKey = b.BranchKey
LEFT JOIN fact.[Transaction] AS f ON f.AccountKey = a.AccountKey
LEFT JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
LEFT JOIN dim.Channel AS ch ON ch.ChannelKey = f.ChannelKey
WHERE b.BranchKey <> -1
GROUP BY b.BranchKey, b.BranchName, b.City, b.Governorate, b.Region;
GO

/* SCD2 audit: what changed for whom, and when. */
CREATE OR ALTER VIEW rpt.vw_CustomerHistory
AS
SELECT c.CustomerID, c.CustomerKey, c.FullName, c.ValidFrom, c.ValidTo, c.IsCurrent,
       VersionNo = ROW_NUMBER() OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.Segment,     PrevSegment     = LAG(c.Segment)     OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.City,        PrevCity        = LAG(c.City)        OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.Governorate, PrevGovernorate = LAG(c.Governorate) OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.IncomeBand,  PrevIncomeBand  = LAG(c.IncomeBand)  OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.RiskRating,  PrevRiskRating  = LAG(c.RiskRating)  OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.KYCStatus,   PrevKYCStatus   = LAG(c.KYCStatus)   OVER (PARTITION BY c.CustomerID ORDER BY c.ValidFrom),
       c.LoadID
FROM dim.Customer AS c
WHERE c.CustomerKey <> -1;
GO

/* Operational views for the "Data quality & lineage" page. */
CREATE OR ALTER VIEW rpt.vw_DataQualityLatest
AS
SELECT r.LoadID, r.CheckName, r.Severity, r.Status, r.Observed, r.Expected, r.Details, r.CheckedAt
FROM audit.DataQualityResult AS r
WHERE r.LoadID = (SELECT MAX(LoadID) FROM audit.DataQualityResult);
GO

CREATE OR ALTER VIEW rpt.vw_LoadRuns
AS
SELECT l.LoadID, l.StepName, l.Status, l.StartedAt, l.EndedAt,
       DurationSec = DATEDIFF(SECOND, l.StartedAt, l.EndedAt),
       l.RowsInserted, l.RowsUpdated, l.RowsRejected, l.ErrorMessage,
       RunDurationSec = DATEDIFF(SECOND, MIN(l.StartedAt) OVER (PARTITION BY l.LoadID), MAX(l.EndedAt) OVER (PARTITION BY l.LoadID))
FROM etl.LoadLog AS l;
GO

PRINT '05_analytics_views.sql completed: 8 views in schema rpt.';
GO
