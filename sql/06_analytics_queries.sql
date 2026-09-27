/* =============================================================================
   06 · Twelve business questions, answered in T-SQL
   -----------------------------------------------------------------------------
   Each block is self-contained.  Techniques on show: window functions with
   frames, LAG/LEAD, NTILE, PERCENTILE_CONT, gaps-and-islands, cohort
   retention, PIVOT, CROSS APPLY top-N, self-joins for affinity, CTE chains.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

/* Q1 — Churn rate by segment and tenure band (from the serving table). */
SELECT Segment, TenureBand,
       Customers        = COUNT(*),
       Churned          = SUM(CASE WHEN IsChurned = 1 THEN 1 ELSE 0 END),
       ChurnRatePct     = CAST(100.0 * SUM(CASE WHEN IsChurned = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)),
       DepositsAtRisk   = SUM(CASE WHEN ChurnRiskBand = 'High' THEN TotalDepositBalance ELSE 0 END),
       AvgProducts      = CAST(AVG(CAST(ProductsHeld AS DECIMAL(5,2))) AS DECIMAL(5,2))
FROM rpt.Customer360
GROUP BY Segment, TenureBand
ORDER BY Segment, CASE TenureBand WHEN '<1 yr' THEN 1 WHEN '1-3 yrs' THEN 2 WHEN '3-6 yrs' THEN 3 ELSE 4 END;
GO

/* Q2 — RFM matrix: how many customers sit in each Recency × Frequency cell, with their money. */
SELECT RecencyScore,
       [F1] = SUM(CASE WHEN FrequencyScore = 1 THEN 1 ELSE 0 END),
       [F2] = SUM(CASE WHEN FrequencyScore = 2 THEN 1 ELSE 0 END),
       [F3] = SUM(CASE WHEN FrequencyScore = 3 THEN 1 ELSE 0 END),
       [F4] = SUM(CASE WHEN FrequencyScore = 4 THEN 1 ELSE 0 END),
       [F5] = SUM(CASE WHEN FrequencyScore = 5 THEN 1 ELSE 0 END),
       Customers = COUNT(*),
       AvgDeposits = CAST(AVG(TotalDepositBalance) AS DECIMAL(16,0)),
       ChurnRatePct = CAST(100.0 * AVG(CAST(IsChurned AS DECIMAL(3,1))) AS DECIMAL(5,1))
FROM rpt.Customer360
GROUP BY RecencyScore
ORDER BY RecencyScore DESC;
GO

/* Q3 — Monthly active customers with month-over-month growth (LAG) and a 3-month moving average. */
;WITH mac AS
(
    SELECT d.MonthKey, COUNT(DISTINCT a.CustomerID) AS ActiveCustomers
    FROM fact.Transaction AS f
    JOIN dim.Date    AS d ON d.DateKey    = f.DateKey
    JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
    GROUP BY d.MonthKey
)
SELECT MonthKey, ActiveCustomers,
       PrevMonth      = LAG(ActiveCustomers) OVER (ORDER BY MonthKey),
       MoMChangePct   = CAST(100.0 * (ActiveCustomers - LAG(ActiveCustomers) OVER (ORDER BY MonthKey))
                             / NULLIF(LAG(ActiveCustomers) OVER (ORDER BY MonthKey), 0) AS DECIMAL(6,2)),
       MovingAvg3M    = CAST(AVG(CAST(ActiveCustomers AS DECIMAL(12,2))) OVER (ORDER BY MonthKey ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS DECIMAL(12,1)),
       YoYChangePct   = CAST(100.0 * (ActiveCustomers - LAG(ActiveCustomers, 12) OVER (ORDER BY MonthKey))
                             / NULLIF(LAG(ActiveCustomers, 12) OVER (ORDER BY MonthKey), 0) AS DECIMAL(6,2))
FROM mac
ORDER BY MonthKey;
GO

/* Q4 — Running balance and maximum drawdown per current account (window frames).
        Drawdown = how far the balance fell from its running peak. */
;WITH ledger AS
(
    SELECT a.AccountID, d.FullDate, f.TxnTime, f.Amount,
           RunningBalance = SUM(f.Amount) OVER (PARTITION BY a.AccountID ORDER BY d.FullDate, f.TxnTime, f.TransactionKey
                                                ROWS UNBOUNDED PRECEDING)
    FROM fact.Transaction AS f
    JOIN dim.Date    AS d ON d.DateKey    = f.DateKey
    JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
    JOIN dim.Product AS p ON p.ProductKey = a.ProductKey
    WHERE p.ProductType = 'Current'
),
peaks AS
(
    SELECT *,
           RunningPeak = MAX(RunningBalance) OVER (PARTITION BY AccountID ORDER BY FullDate, TxnTime ROWS UNBOUNDED PRECEDING)
    FROM ledger
)
SELECT TOP (20) AccountID,
       FinalBalance   = MAX(CASE WHEN rn = 1 THEN RunningBalance END),
       PeakBalance    = MAX(RunningPeak),
       MaxDrawdown    = MAX(RunningPeak - RunningBalance),
       Transactions   = COUNT(*)
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY AccountID ORDER BY FullDate DESC, TxnTime DESC) AS rn FROM peaks) AS x
GROUP BY AccountID
ORDER BY MaxDrawdown DESC;
GO

/* Q5 — Dormancy streaks (gaps & islands): accounts dormant for 3+ consecutive months, with the streak boundaries. */
;WITH flagged AS
(
    SELECT s.AccountKey, s.MonthKey,
           MonthSeq = DENSE_RANK() OVER (ORDER BY s.MonthKey),          -- consecutive integer per month
           IsIdle   = CASE WHEN s.TxnCount = 0 THEN 1 ELSE 0 END
    FROM fact.AccountMonthSnapshot AS s
    WHERE s.IsOpen = 1
),
islands AS
(
    SELECT AccountKey, MonthKey, MonthSeq,
           Grp = MonthSeq - ROW_NUMBER() OVER (PARTITION BY AccountKey ORDER BY MonthSeq)   -- constant within a run
    FROM flagged
    WHERE IsIdle = 1
),
streaks AS
(
    SELECT AccountKey, MIN(MonthKey) AS StreakStart, MAX(MonthKey) AS StreakEnd, COUNT(*) AS StreakMonths
    FROM islands
    GROUP BY AccountKey, Grp
    HAVING COUNT(*) >= 3
)
SELECT c.Segment, p.ProductType,
       AccountsWithStreak = COUNT(DISTINCT st.AccountKey),
       AvgStreakMonths    = CAST(AVG(CAST(st.StreakMonths AS DECIMAL(5,2))) AS DECIMAL(5,2)),
       LongestStreak      = MAX(st.StreakMonths),
       StillDormantNow    = SUM(CASE WHEN st.StreakEnd = (SELECT MAX(MonthKey) FROM fact.AccountMonthSnapshot) THEN 1 ELSE 0 END)
FROM streaks AS st
JOIN dim.Account  AS a ON a.AccountKey = st.AccountKey
JOIN dim.Product  AS p ON p.ProductKey = a.ProductKey
JOIN dim.Customer AS c ON c.CustomerID = a.CustomerID AND c.IsCurrent = 1
GROUP BY c.Segment, p.ProductType
ORDER BY AccountsWithStreak DESC;
GO

/* Q6 — Cohort retention: of customers onboarded in each quarter, what share transacted in each later quarter? */
;WITH cohort AS
(
    SELECT c.CustomerID, CohortQ = MIN(d.QuarterLabel), CohortStart = MIN(d.FullDate)
    FROM dim.Customer AS c
    JOIN dim.Date AS d ON d.FullDate = c.OnboardDate
    WHERE c.IsCurrent = 1 AND c.CustomerKey <> -1 AND c.OnboardDate >= '2024-01-01'
    GROUP BY c.CustomerID
),
activity AS
(
    SELECT DISTINCT a.CustomerID, d.QuarterLabel, d.CalendarYear, d.QuarterNumber
    FROM fact.Transaction AS f
    JOIN dim.Date    AS d ON d.DateKey    = f.DateKey
    JOIN dim.Account AS a ON a.AccountKey = f.AccountKey
),
matrix AS
(
    SELECT co.CohortQ,
           QuartersSince = (act.CalendarYear * 4 + act.QuarterNumber) - (YEAR(co.CohortStart) * 4 + DATEPART(QUARTER, co.CohortStart)),
           co.CustomerID
    FROM cohort AS co
    JOIN activity AS act ON act.CustomerID = co.CustomerID
)
SELECT CohortQ,
       CohortSize = (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ),
       [Q+0] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 0 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1)),
       [Q+1] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 1 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1)),
       [Q+2] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 2 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1)),
       [Q+3] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 3 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1)),
       [Q+4] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 4 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1)),
       [Q+5] = CAST(100.0 * COUNT(DISTINCT CASE WHEN QuartersSince = 5 THEN CustomerID END) / (SELECT COUNT(*) FROM cohort c WHERE c.CohortQ = m.CohortQ) AS DECIMAL(5,1))
FROM matrix AS m
GROUP BY CohortQ
ORDER BY CohortQ;
GO

/* Q7 — Channel mix by month as a crosstab (PIVOT): is the branch losing share to mobile? */
SELECT MonthKey, [Mobile], [Internet], [ATM], [POS], [Branch], [CallCenter],
       DigitalSharePct = CAST(100.0 * ([Mobile] + [Internet]) / NULLIF([Mobile] + [Internet] + [ATM] + [POS] + [Branch] + [CallCenter], 0) AS DECIMAL(5,1))
FROM
(
    SELECT d.MonthKey, ch.ChannelName, f.TransactionKey
    FROM fact.Transaction AS f
    JOIN dim.Date    AS d  ON d.DateKey     = f.DateKey
    JOIN dim.Channel AS ch ON ch.ChannelKey = f.ChannelKey
    WHERE ch.ChannelName <> 'System'
) AS q
PIVOT (COUNT(TransactionKey) FOR ChannelName IN ([Mobile], [Internet], [ATM], [POS], [Branch], [CallCenter])) AS pvt
ORDER BY MonthKey;
GO

/* Q8 — Top-3 merchant categories per segment by card spend (CROSS APPLY top-N per group). */
SELECT seg.Segment, t.MerchantCategory, t.Spend, t.Rnk
FROM (SELECT DISTINCT Segment FROM dim.Customer WHERE IsCurrent = 1 AND CustomerKey <> -1) AS seg
CROSS APPLY
(
    SELECT TOP (3) f.MerchantCategory, Spend = SUM(-f.Amount),
           Rnk = ROW_NUMBER() OVER (ORDER BY SUM(-f.Amount) DESC)
    FROM fact.Transaction AS f
    JOIN dim.Customer AS c ON c.CustomerKey = f.CustomerKey
    JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
    WHERE c.Segment = seg.Segment AND tt.TxnType = 'CardPurchase'
    GROUP BY f.MerchantCategory
    ORDER BY Spend DESC
) AS t
ORDER BY seg.Segment, t.Rnk;
GO

/* Q9 — Branch league table: RANK, DENSE_RANK, NTILE and PERCENT_RANK side by side. */
SELECT BranchName, Region, Customers, TxnCount, FeeIncome,
       RankByFee       = RANK()         OVER (ORDER BY FeeIncome DESC),
       DenseRankByFee  = DENSE_RANK()   OVER (ORDER BY FeeIncome DESC),
       Quartile        = NTILE(4)       OVER (ORDER BY FeeIncome DESC),
       PercentRank     = CAST(PERCENT_RANK() OVER (ORDER BY FeeIncome) AS DECIMAL(5,3)),
       RankInRegion    = RANK()         OVER (PARTITION BY Region ORDER BY FeeIncome DESC),
       FeePerCustomer  = CAST(FeeIncome / NULLIF(Customers, 0) AS DECIMAL(12,2))
FROM rpt.vw_BranchPerformance
ORDER BY RankByFee;
GO

/* Q10 — Complaint resolution SLA: median and 90th percentile resolution days by category (PERCENTILE_CONT). */
SELECT DISTINCT Category,
       Resolved      = COUNT(*)                          OVER (PARTITION BY Category),
       MedianDays    = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ResolutionDays) OVER (PARTITION BY Category),
       P90Days       = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY ResolutionDays) OVER (PARTITION BY Category),
       AvgDays       = CAST(AVG(CAST(ResolutionDays AS DECIMAL(6,2))) OVER (PARTITION BY Category) AS DECIMAL(6,2)),
       WithinSLA7Pct = CAST(100.0 * SUM(CASE WHEN ResolutionDays <= 7 THEN 1 ELSE 0 END) OVER (PARTITION BY Category)
                            / COUNT(*) OVER (PARTITION BY Category) AS DECIMAL(5,1))
FROM fact.Complaint
WHERE Status = 'Resolved' AND ResolutionDays IS NOT NULL
ORDER BY P90Days DESC;
GO

/* Q11 — Cross-sell affinity: which product pairs are held together most often (self-join on holdings)? */
;WITH holdings AS
(
    SELECT DISTINCT a.CustomerID, p.ProductType
    FROM dim.Account AS a JOIN dim.Product AS p ON p.ProductKey = a.ProductKey
    WHERE a.IsOpen = 1
),
pairs AS
(
    SELECT h1.ProductType AS ProductA, h2.ProductType AS ProductB, COUNT(*) AS CustomersWithBoth
    FROM holdings AS h1
    JOIN holdings AS h2 ON h2.CustomerID = h1.CustomerID AND h2.ProductType > h1.ProductType
    GROUP BY h1.ProductType, h2.ProductType
),
singles AS
(
    SELECT ProductType, COUNT(*) AS Holders FROM holdings GROUP BY ProductType
)
SELECT p.ProductA, p.ProductB, p.CustomersWithBoth,
       HoldersA = sa.Holders, HoldersB = sb.Holders,
       AttachRateAtoB_Pct = CAST(100.0 * p.CustomersWithBoth / sa.Holders AS DECIMAL(5,1)),   -- of A holders, % who also hold B
       Lift = CAST((1.0 * p.CustomersWithBoth / sa.Holders) / (1.0 * sb.Holders / (SELECT COUNT(DISTINCT CustomerID) FROM holdings)) AS DECIMAL(6,2))
FROM pairs AS p
JOIN singles AS sa ON sa.ProductType = p.ProductA
JOIN singles AS sb ON sb.ProductType = p.ProductB
ORDER BY p.CustomersWithBoth DESC;
GO

/* Q12 — Behaviour after payday: how fast does salary leave the account?  Share of the month's salary
         spent/withdrawn within 3, 7 and 14 days, by income band. */
;WITH salary AS
(
    SELECT f.AccountKey, a.CustomerID, c.IncomeBand, d.FullDate AS PayDate, f.Amount AS Salary
    FROM fact.Transaction AS f
    JOIN dim.TransactionType AS tt ON tt.TxnTypeKey = f.TxnTypeKey
    JOIN dim.Date     AS d ON d.DateKey     = f.DateKey
    JOIN dim.Account  AS a ON a.AccountKey  = f.AccountKey
    JOIN dim.Customer AS c ON c.CustomerKey = f.CustomerKey
    WHERE tt.TxnType = 'Salary'
),
outflow AS
(
    SELECT s.IncomeBand, s.Salary,
           Out3  = SUM(CASE WHEN d.FullDate <= DATEADD(DAY, 3,  s.PayDate) THEN -f.Amount ELSE 0 END),
           Out7  = SUM(CASE WHEN d.FullDate <= DATEADD(DAY, 7,  s.PayDate) THEN -f.Amount ELSE 0 END),
           Out14 = SUM(CASE WHEN d.FullDate <= DATEADD(DAY, 14, s.PayDate) THEN -f.Amount ELSE 0 END)
    FROM salary AS s
    JOIN fact.Transaction AS f ON f.AccountKey = s.AccountKey AND f.Amount < 0
    JOIN dim.Date AS d ON d.DateKey = f.DateKey
    WHERE d.FullDate BETWEEN s.PayDate AND DATEADD(DAY, 14, s.PayDate)
    GROUP BY s.AccountKey, s.PayDate, s.IncomeBand, s.Salary
)
SELECT IncomeBand,
       PayCycles         = COUNT(*),
       AvgSalary         = CAST(AVG(Salary) AS DECIMAL(12,0)),
       SpentIn3DaysPct   = CAST(100.0 * SUM(Out3)  / SUM(Salary) AS DECIMAL(5,1)),
       SpentIn7DaysPct   = CAST(100.0 * SUM(Out7)  / SUM(Salary) AS DECIMAL(5,1)),
       SpentIn14DaysPct  = CAST(100.0 * SUM(Out14) / SUM(Salary) AS DECIMAL(5,1))
FROM outflow
GROUP BY IncomeBand
ORDER BY CASE IncomeBand WHEN '<5k' THEN 1 WHEN '5-15k' THEN 2 WHEN '15-30k' THEN 3 WHEN '30-60k' THEN 4 ELSE 5 END;
GO
