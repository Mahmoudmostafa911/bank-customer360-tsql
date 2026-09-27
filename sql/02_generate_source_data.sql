/* =============================================================================
   02 · Generate the synthetic core-banking extracts — 100 % set-based T-SQL
   -----------------------------------------------------------------------------
   ~20,000 customers · ~32,000 accounts · ~1,000,000 transactions · ~6,000
   complaints for a fictional Egyptian retail bank ("Nile Bank"), covering the
   24 months 2024-01-01 .. 2025-12-31.

   Design notes
   • No loops, no RAND(), no NEWID(): every value comes from etl.fn_Rnd(salt, n),
     a deterministic hash, so the dataset is fully reproducible.
   • Behaviour is baked in on purpose so the analytics have something to find:
     12 % of customers "attrite" (their activity stops at a hidden date), older
     customers use branches more, affluent customers hold more products, and
     complaints cluster around attriting customers.
   • Defects are planted deliberately (duplicates, orphans, future dates, NULL
     keys, dirty text) — the staging layer has to catch them.
   Runtime: ~1–3 minutes on a laptop.  Re-runnable: truncates src.* first.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Customers      INT  = 20000;
DECLARE @RandomTxns     INT  = 650000;
DECLARE @WindowStart    DATE = '2024-01-01';
DECLARE @WindowEnd      DATE = '2025-12-31';
DECLARE @SnapshotDate   DATE = '2025-12-31';
DECLARE @WindowDays     INT  = DATEDIFF(DAY, @WindowStart, @WindowEnd) + 1;   -- 731
DECLARE @t0 DATETIME2(0) = SYSUTCDATETIME();

TRUNCATE TABLE src.CustomerExtract;
TRUNCATE TABLE src.BranchExtract;
TRUNCATE TABLE src.ProductExtract;
TRUNCATE TABLE src.AccountExtract;
TRUNCATE TABLE src.TransactionExtract;
TRUNCATE TABLE src.ComplaintExtract;

/* ---------------------------------------------------------------- reference data */
INSERT INTO src.ProductExtract (ProductID, ProductCode, ProductName, ProductType, IsLiability, AnnualRatePct)
VALUES (1, 'CUR-STD', N'Everyday Current Account', 'Current',      1,  0.00),
       (2, 'SAV-FLX', N'Flexi Savings',            'Savings',      1, 12.50),
       (3, 'FD-12M',  N'12-Month Fixed Deposit',   'FixedDeposit', 1, 18.00),
       (4, 'CC-CLS',  N'Classic Credit Card',      'CreditCard',   0, 32.00),
       (5, 'CC-PLT',  N'Platinum Credit Card',     'CreditCard',   0, 29.00),
       (6, 'PL-STD',  N'Personal Loan',            'PersonalLoan', 0, 21.75),
       (7, 'AL-STD',  N'Auto Loan',                'AutoLoan',     0, 19.50),
       (8, 'MG-STD',  N'Home Mortgage',            'Mortgage',     0, 16.00);

INSERT INTO src.BranchExtract (BranchID, BranchCode, BranchName, City, Governorate, Region, OpenedYear)
VALUES (1,  'CAI-01', N'Cairo – Nasr City',        N'Cairo',        N'Cairo',        'Greater Cairo', 1998),
       (2,  'CAI-02', N'Cairo – Heliopolis',       N'Cairo',        N'Cairo',        'Greater Cairo', 2001),
       (3,  'CAI-03', N'Cairo – Maadi',            N'Cairo',        N'Cairo',        'Greater Cairo', 2004),
       (4,  'CAI-04', N'Cairo – New Cairo',        N'New Cairo',    N'Cairo',        'Greater Cairo', 2012),
       (5,  'CAI-05', N'Cairo – Downtown',         N'Cairo',        N'Cairo',        'Greater Cairo', 1995),
       (6,  'CAI-06', N'Cairo – Zamalek',          N'Cairo',        N'Cairo',        'Greater Cairo', 1999),
       (7,  'GIZ-01', N'Giza – Dokki',             N'Giza',         N'Giza',         'Greater Cairo', 2000),
       (8,  'GIZ-02', N'Giza – Mohandessin',       N'Giza',         N'Giza',         'Greater Cairo', 2003),
       (9,  'GIZ-03', N'6th of October City',      N'6th of October', N'Giza',       'Greater Cairo', 2010),
       (10, 'GIZ-04', N'Sheikh Zayed',             N'Sheikh Zayed', N'Giza',         'Greater Cairo', 2015),
       (11, 'ALX-01', N'Alexandria – Smouha',      N'Alexandria',   N'Alexandria',   'Delta & Coast', 1997),
       (12, 'ALX-02', N'Alexandria – Miami',       N'Alexandria',   N'Alexandria',   'Delta & Coast', 2006),
       (13, 'ALX-03', N'Alexandria – Mansheya',    N'Alexandria',   N'Alexandria',   'Delta & Coast', 1996),
       (14, 'QAL-01', N'Shubra El Kheima',         N'Shubra El Kheima', N'Qalyubia', 'Greater Cairo', 2008),
       (15, 'QAL-02', N'Banha',                    N'Banha',        N'Qalyubia',     'Delta & Coast', 2011),
       (16, 'DAK-01', N'Mansoura',                 N'Mansoura',     N'Dakahlia',     'Delta & Coast', 2002),
       (17, 'DAK-02', N'Mansoura – University',    N'Mansoura',     N'Dakahlia',     'Delta & Coast', 2016),
       (18, 'SHR-01', N'Zagazig',                  N'Zagazig',      N'Sharqia',      'Delta & Coast', 2005),
       (19, 'GHR-01', N'Tanta',                    N'Tanta',        N'Gharbia',      'Delta & Coast', 2004),
       (20, 'MNF-01', N'Shebin El Kom',            N'Shebin El Kom', N'Monufia',     'Delta & Coast', 2013),
       (21, 'BHR-01', N'Damanhur',                 N'Damanhur',     N'Beheira',      'Delta & Coast', 2009),
       (22, 'ISM-01', N'Ismailia',                 N'Ismailia',     N'Ismailia',     'Canal',         2007),
       (23, 'PSD-01', N'Port Said',                N'Port Said',    N'Port Said',    'Canal',         2001),
       (24, 'SUZ-01', N'Suez',                     N'Suez',         N'Suez',         'Canal',         2010),
       (25, 'FAY-01', N'Fayoum',                   N'Fayoum',       N'Fayoum',       'Upper Egypt',   2012),
       (26, 'MIN-01', N'Minya',                    N'Minya',        N'Minya',        'Upper Egypt',   2008),
       (27, 'ASY-01', N'Assiut',                   N'Assiut',       N'Assiut',       'Upper Egypt',   2003),
       (28, 'SOH-01', N'Sohag',                    N'Sohag',        N'Sohag',        'Upper Egypt',   2014),
       (29, 'LUX-01', N'Luxor',                    N'Luxor',        N'Luxor',        'Upper Egypt',   2006),
       (30, 'ASW-01', N'Aswan',                    N'Aswan',        N'Aswan',        'Upper Egypt',   2009),
       (31, 'RDS-01', N'Hurghada',                 N'Hurghada',     N'Red Sea',      'Red Sea & Sinai', 2011),
       (32, 'SSN-01', N'Sharm El Sheikh',          N'Sharm El Sheikh', N'South Sinai', 'Red Sea & Sinai', 2013),
       (33, 'CAI-07', N'Cairo – Madinaty',         N'New Cairo',    N'Cairo',        'Greater Cairo', 2019),
       (34, 'GIZ-05', N'Giza – Haram',             N'Giza',         N'Giza',         'Greater Cairo', 2005),
       (35, 'ALX-04', N'Alexandria – Borg El Arab', N'Borg El Arab', N'Alexandria',  'Delta & Coast', 2018),
       (36, 'CAI-08', N'Cairo – Mokattam',         N'Cairo',        N'Cairo',        'Greater Cairo', 2017),
       (37, 'DAK-03', N'Damietta',                 N'Damietta',     N'Damietta',     'Delta & Coast', 2012),
       (38, 'KFS-01', N'Kafr El Sheikh',           N'Kafr El Sheikh', N'Kafr El Sheikh', 'Delta & Coast', 2015),
       (39, 'BNS-01', N'Beni Suef',                N'Beni Suef',    N'Beni Suef',    'Upper Egypt',   2016),
       (40, 'QEN-01', N'Qena',                     N'Qena',         N'Qena',         'Upper Egypt',   2017);

/* Governorate mix of the customer base (weights sum to 1). */
IF OBJECT_ID('tempdb..#Geo') IS NOT NULL DROP TABLE #Geo;
CREATE TABLE #Geo (Governorate NVARCHAR(60) PRIMARY KEY, City NVARCHAR(60), Weight DECIMAL(6,4));
INSERT INTO #Geo VALUES
 (N'Cairo', N'Cairo', 0.34), (N'Giza', N'Giza', 0.19), (N'Alexandria', N'Alexandria', 0.12),
 (N'Qalyubia', N'Banha', 0.05), (N'Dakahlia', N'Mansoura', 0.05), (N'Sharqia', N'Zagazig', 0.04),
 (N'Gharbia', N'Tanta', 0.03), (N'Monufia', N'Shebin El Kom', 0.02), (N'Beheira', N'Damanhur', 0.02),
 (N'Ismailia', N'Ismailia', 0.02), (N'Port Said', N'Port Said', 0.02), (N'Suez', N'Suez', 0.01),
 (N'Fayoum', N'Fayoum', 0.01), (N'Minya', N'Minya', 0.02), (N'Assiut', N'Assiut', 0.02),
 (N'Sohag', N'Sohag', 0.01), (N'Luxor', N'Luxor', 0.01), (N'Aswan', N'Aswan', 0.01),
 (N'Red Sea', N'Hurghada', 0.01);

DECLARE @GeoWeights VARCHAR(400) =
    (SELECT STRING_AGG(CONCAT(Governorate, ':', CAST(Weight AS VARCHAR(10))), '|') FROM #Geo);

IF OBJECT_ID('tempdb..#FirstNames') IS NOT NULL DROP TABLE #FirstNames;
CREATE TABLE #FirstNames (Gender CHAR(1), Idx INT, Name NVARCHAR(40), PRIMARY KEY (Gender, Idx));
INSERT INTO #FirstNames (Gender, Idx, Name)
SELECT 'M', ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), v.n
FROM (VALUES (N'Ahmed'),(N'Mohamed'),(N'Mahmoud'),(N'Omar'),(N'Youssef'),(N'Karim'),(N'Khaled'),(N'Hassan'),(N'Amr'),(N'Tarek'),
             (N'Mostafa'),(N'Ali'),(N'Ibrahim'),(N'Hossam'),(N'Sherif'),(N'Ayman'),(N'Waleed'),(N'Ramy'),(N'Sameh'),(N'Adham'),
             (N'Ziad'),(N'Hany'),(N'Maged'),(N'Fady'),(N'Peter'),(N'Mina'),(N'George'),(N'Bassem'),(N'Islam'),(N'Seif')) AS v(n)
UNION ALL
SELECT 'F', ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), v.n
FROM (VALUES (N'Sara'),(N'Nour'),(N'Mariam'),(N'Salma'),(N'Hana'),(N'Farah'),(N'Yasmin'),(N'Menna'),(N'Rana'),(N'Aya'),
             (N'Dina'),(N'Heba'),(N'Nadine'),(N'Reem'),(N'Layla'),(N'Malak'),(N'Shahd'),(N'Nada'),(N'Mai'),(N'Hoda'),
             (N'Marwa'),(N'Amira'),(N'Esraa'),(N'Rania'),(N'Mona'),(N'Mirna'),(N'Christine'),(N'Nancy'),(N'Sandra'),(N'Jana')) AS v(n);

IF OBJECT_ID('tempdb..#LastNames') IS NOT NULL DROP TABLE #LastNames;
CREATE TABLE #LastNames (Idx INT PRIMARY KEY, Name NVARCHAR(40));
INSERT INTO #LastNames (Idx, Name)
SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), v.n
FROM (VALUES (N'Hassan'),(N'Ibrahim'),(N'Mostafa'),(N'Abdelrahman'),(N'El Sayed'),(N'Mahmoud'),(N'Farouk'),(N'Fathy'),(N'Salem'),(N'Adel'),
             (N'Kamal'),(N'Nabil'),(N'Saleh'),(N'Ramadan'),(N'Zaki'),(N'Hamdy'),(N'Gaber'),(N'Shawky'),(N'El Masry'),(N'Amin'),
             (N'Lotfy'),(N'Rashad'),(N'Samir'),(N'Anwar'),(N'Ezzat'),(N'Fahmy'),(N'Younis'),(N'Abbas'),(N'Girgis'),(N'Sobhy'),
             (N'Wahba'),(N'Naguib'),(N'Tawfik'),(N'Hegazy'),(N'Darwish'),(N'Osman'),(N'Khalil'),(N'Mansour'),(N'Bakr'),(N'Sultan')) AS v(n);

/* ---------------------------------------------------------------- customers */
INSERT INTO src.CustomerExtract
      (CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus,
       IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt)
SELECT
    base.CustomerID,
    fn.Name,
    ln.Name,
    -- the extract is inconsistent on purpose: M / F / Male / Female
    CASE WHEN rG2.v < 0.85 THEN base.Gender ELSE CASE base.Gender WHEN 'M' THEN 'Male' ELSE 'Female' END END,
    CASE WHEN rBad.v < 0.002 THEN '31/02/' + CAST(YEAR(base.BirthDate) AS VARCHAR(4))   -- malformed (dd/mm/yyyy + impossible day)
         WHEN rBad.v < 0.003 THEN NULL
         ELSE CONVERT(VARCHAR(10), base.BirthDate, 23) END,
    base.Segment,
    -- dirty city text: lower-case, upper-case, padding
    CASE WHEN rCity.v < 0.08 THEN LOWER(g.City)
         WHEN rCity.v < 0.11 THEN UPPER(g.City)
         WHEN rCity.v < 0.16 THEN N'  ' + g.City + N' '
         ELSE g.City END,
    g.Governorate,
    c.EmploymentStatus,
    c.IncomeBand,
    CASE WHEN rRisk.v < 0.70 THEN 'Low' WHEN rRisk.v < 0.92 THEN 'Medium' ELSE 'High' END,
    CASE WHEN rKyc.v  < 0.93 THEN 'Verified' WHEN rKyc.v < 0.98 THEN 'Pending' ELSE 'Expired' END,
    base.OnboardDate,
    CAST(DATEADD(DAY, CAST(FLOOR(rUpd.v * 300) AS INT), base.OnboardDate) AS DATETIME2(0))
FROM
(
    SELECT
        num.n AS CustomerID,
        Gender = CASE WHEN rG.v < 0.55 THEN 'M' ELSE 'F' END,
        Age    = CAST(18 + FLOOR(POWER(rA.v, 1.25) * 57) AS INT),
        BirthDate = DATEADD(DAY, -CAST(FLOOR(rB.v * 365) AS INT),
                            DATEADD(YEAR, -CAST(18 + FLOOR(POWER(rA.v, 1.25) * 57) AS INT), @SnapshotDate)),
        Segment = seg.label,
        OnboardDate = DATEADD(DAY, CAST(FLOOR(POWER(rO.v, 0.7) * DATEDIFF(DAY, '2016-01-01', '2025-06-30')) AS INT), CAST('2016-01-01' AS DATE)),
        GeoLabel = geo.label,
        rF = rF.v, rL = rL.v, rE = rE.v, rI = rI.v
    FROM etl.Numbers AS num
    CROSS APPLY etl.fn_Rnd('gender',  num.n) AS rG
    CROSS APPLY etl.fn_Rnd('age',     num.n) AS rA
    CROSS APPLY etl.fn_Rnd('bday',    num.n) AS rB
    CROSS APPLY etl.fn_Rnd('segment', num.n) AS rS
    CROSS APPLY etl.fn_Rnd('onboard', num.n) AS rO
    CROSS APPLY etl.fn_Rnd('geo',     num.n) AS rGeo
    CROSS APPLY etl.fn_Rnd('fname',   num.n) AS rF
    CROSS APPLY etl.fn_Rnd('lname',   num.n) AS rL
    CROSS APPLY etl.fn_Rnd('employ',  num.n) AS rE
    CROSS APPLY etl.fn_Rnd('income',  num.n) AS rI
    CROSS APPLY etl.fn_PickWeighted('Retail:0.70|Affluent:0.18|SME:0.08|Private:0.04', rS.v) AS seg
    CROSS APPLY etl.fn_PickWeighted(@GeoWeights, rGeo.v) AS geo
    WHERE num.n <= @Customers
) AS base
CROSS APPLY
(
    SELECT
        EmploymentStatus = CASE WHEN base.Age >= 62 THEN 'Retired'
                                WHEN base.Age <= 22 AND base.rE < 0.55 THEN 'Student'
                                WHEN base.rE < 0.62 THEN 'Employed'
                                WHEN base.rE < 0.82 THEN 'Self-employed'
                                WHEN base.rE < 0.90 THEN 'Retired'
                                WHEN base.rE < 0.96 THEN 'Unemployed'
                                ELSE 'Employed' END,
        IncomeBand = CASE base.Segment
                        WHEN 'Private'  THEN '60k+'
                        WHEN 'Affluent' THEN CASE WHEN base.rI < 0.6 THEN '30-60k' ELSE '60k+' END
                        WHEN 'SME'      THEN CASE WHEN base.rI < 0.5 THEN '15-30k' WHEN base.rI < 0.85 THEN '30-60k' ELSE '60k+' END
                        ELSE CASE WHEN base.rI < 0.15 THEN '<5k' WHEN base.rI < 0.60 THEN '5-15k' WHEN base.rI < 0.90 THEN '15-30k' ELSE '30-60k' END
                     END
) AS c
JOIN #Geo        AS g  ON g.Governorate = base.GeoLabel
JOIN #FirstNames AS fn ON fn.Gender = base.Gender AND fn.Idx = CAST(1 + FLOOR(base.rF * 30) AS INT)
JOIN #LastNames  AS ln ON ln.Idx = CAST(1 + FLOOR(base.rL * 40) AS INT)
CROSS APPLY etl.fn_Rnd('gender2', base.CustomerID) AS rG2
CROSS APPLY etl.fn_Rnd('badday',  base.CustomerID) AS rBad
CROSS APPLY etl.fn_Rnd('city',    base.CustomerID) AS rCity
CROSS APPLY etl.fn_Rnd('risk',    base.CustomerID) AS rRisk
CROSS APPLY etl.fn_Rnd('kyc',     base.CustomerID) AS rKyc
CROSS APPLY etl.fn_Rnd('upd',     base.CustomerID) AS rUpd;

PRINT CONCAT('customers generated: ', @@ROWCOUNT);

/* planted defects ------------------------------------------------------------
   a) 50 exact duplicate rows (the extract was re-sent)
   b) 30 "newer versions" with a changed city and later UpdatedAt  → staging must keep the latest
   c) 10 rows with NULL CustomerID                                  → reject
*/
INSERT INTO src.CustomerExtract (CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt)
SELECT CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt
FROM src.CustomerExtract WHERE CustomerID % 400 = 7;

INSERT INTO src.CustomerExtract (CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt)
SELECT CustomerID, FirstName, LastName, Gender, BirthDate, Segment, N'New Cairo', N'Cairo', EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate,
       DATEADD(DAY, 400, UpdatedAt)
FROM src.CustomerExtract WHERE CustomerID % 667 = 3;

INSERT INTO src.CustomerExtract (CustomerID, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt)
SELECT TOP (10) NULL, FirstName, LastName, Gender, BirthDate, Segment, City, Governorate, EmploymentStatus, IncomeBand, RiskRating, KYCStatus, OnboardDate, UpdatedAt
FROM src.CustomerExtract ORDER BY CustomerID;

/* ---------------------------------------------------------------- accounts */
IF OBJECT_ID('tempdb..#Cust') IS NOT NULL DROP TABLE #Cust;
SELECT CustomerID, Segment, IncomeBand, EmploymentStatus, Governorate, OnboardDate,
       Age = DATEDIFF(YEAR, TRY_CONVERT(DATE, BirthDate, 23), @SnapshotDate),
       -- hidden behaviour: 12 % of customers attrite at a date in Mar–Sep 2025
       StopDate = CASE WHEN rC.v < 0.12
                       THEN DATEADD(DAY, FLOOR(rCd.v * 213), CAST('2025-03-01' AS DATE)) END
INTO #Cust
FROM (SELECT CustomerID, Segment, IncomeBand, EmploymentStatus, Governorate, OnboardDate, BirthDate,
             ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY UpdatedAt DESC) AS rn
      FROM src.CustomerExtract WHERE CustomerID IS NOT NULL) AS x
CROSS APPLY etl.fn_Rnd('churn',  x.CustomerID) AS rC
CROSS APPLY etl.fn_Rnd('churnd', x.CustomerID) AS rCd
WHERE x.rn = 1;
CREATE UNIQUE CLUSTERED INDEX ux_Cust ON #Cust (CustomerID);

IF OBJECT_ID('tempdb..#Acct') IS NOT NULL DROP TABLE #Acct;
CREATE TABLE #Acct
(
    Seq          INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID   INT, ProductID INT, ProductType VARCHAR(20), OpenOffsetDays INT, r DECIMAL(9,6)
);
-- everyone gets a current account; other products by propensity
INSERT INTO #Acct (CustomerID, ProductID, ProductType, OpenOffsetDays, r)
SELECT c.CustomerID, 1, 'Current', 0, r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_cur', c.CustomerID) r1
UNION ALL
SELECT c.CustomerID, 2, 'Savings', 30 + FLOOR(r1.v * 600), r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_sav', c.CustomerID) r1
WHERE r1.v < CASE c.Segment WHEN 'Retail' THEN 0.42 WHEN 'SME' THEN 0.35 ELSE 0.75 END
UNION ALL
SELECT c.CustomerID, 3, 'FixedDeposit', 60 + FLOOR(r1.v * 900), r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_fd', c.CustomerID) r1
WHERE r1.v < CASE c.Segment WHEN 'Retail' THEN 0.07 WHEN 'SME' THEN 0.10 ELSE 0.45 END
UNION ALL
SELECT c.CustomerID, CASE WHEN c.Segment IN ('Affluent','Private') THEN 5 ELSE 4 END, 'CreditCard', 15 + FLOOR(r1.v * 700), r1.v
FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_cc', c.CustomerID) r1
WHERE r1.v < CASE c.Segment WHEN 'Retail' THEN 0.28 WHEN 'SME' THEN 0.30 ELSE 0.65 END AND c.Age >= 21
UNION ALL
SELECT c.CustomerID, 6, 'PersonalLoan', 90 + FLOOR(r1.v * 900), r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_pl', c.CustomerID) r1
WHERE r1.v < 0.12 AND c.EmploymentStatus IN ('Employed','Self-employed')
UNION ALL
SELECT c.CustomerID, 7, 'AutoLoan', 120 + FLOOR(r1.v * 900), r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_al', c.CustomerID) r1
WHERE r1.v < 0.05 AND c.IncomeBand IN ('15-30k','30-60k','60k+')
UNION ALL
SELECT c.CustomerID, 8, 'Mortgage', 200 + FLOOR(r1.v * 900), r1.v FROM #Cust c CROSS APPLY etl.fn_Rnd('acc_mg', c.CustomerID) r1
WHERE r1.v < 0.03 AND c.IncomeBand IN ('30-60k','60k+');

INSERT INTO src.AccountExtract (AccountID, CustomerID, ProductID, BranchID, AccountNo, Currency, OpenDate, CloseDate, Status, CreditLimit, UpdatedAt)
SELECT
    100000 + a.Seq,
    a.CustomerID,
    a.ProductID,
    b.BranchID,
    CONCAT('NB', RIGHT('000000' + CAST(a.CustomerID AS VARCHAR(6)), 6), '-', RIGHT('00' + CAST(a.ProductID AS VARCHAR(2)), 2)),
    CASE WHEN a.ProductType = 'Savings' AND rCur.v < 0.06 THEN 'USD' ELSE 'EGP' END,
    x.OpenDate,
    CASE WHEN x.Status = 'Closed' THEN DATEADD(DAY, 200 + FLOOR(rSt.v * 400), x.OpenDate) END,
    x.Status,
    CASE WHEN a.ProductType = 'CreditCard'
         THEN CASE c.IncomeBand WHEN '<5k' THEN 10000 WHEN '5-15k' THEN 25000 WHEN '15-30k' THEN 60000 WHEN '30-60k' THEN 150000 ELSE 400000 END
         END,
    CAST(x.OpenDate AS DATETIME2(0))
FROM #Acct a
JOIN #Cust c ON c.CustomerID = a.CustomerID
CROSS APPLY etl.fn_Rnd('acc_cur2', a.Seq) AS rCur
CROSS APPLY etl.fn_Rnd('acc_stat', a.Seq) AS rSt
CROSS APPLY etl.fn_Rnd('acc_br',   a.Seq) AS rBr
CROSS APPLY
(
    SELECT OpenDate = CASE WHEN DATEADD(DAY, a.OpenOffsetDays, c.OnboardDate) > '2025-11-30' THEN '2025-11-30'
                           ELSE DATEADD(DAY, a.OpenOffsetDays, c.OnboardDate) END,
           Status   = CASE WHEN a.ProductType = 'Current' AND rSt.v < 0.97 THEN 'Active'
                           WHEN rSt.v < 0.86 THEN 'Active'
                           WHEN rSt.v < 0.93 THEN 'Dormant'
                           WHEN rSt.v < 0.985 THEN 'Closed'
                           ELSE 'Frozen' END
) AS x
CROSS APPLY
(
    -- a branch in the customer's governorate (fallback: Cairo head office) — pick by hash among candidates
    SELECT TOP (1) BranchID
    FROM (SELECT BranchID, ROW_NUMBER() OVER (ORDER BY BranchID) AS rn, COUNT(*) OVER () AS cnt
          FROM src.BranchExtract br
          WHERE br.Governorate = c.Governorate) AS cand
    WHERE cand.rn = 1 + FLOOR(rBr.v * cand.cnt)
    UNION ALL
    SELECT 5 WHERE NOT EXISTS (SELECT 1 FROM src.BranchExtract br WHERE br.Governorate = c.Governorate)
) AS b;

PRINT CONCAT('accounts generated: ', @@ROWCOUNT);

/* planted defects: 25 orphan accounts (customer does not exist) + 40 duplicated rows */
INSERT INTO src.AccountExtract (AccountID, CustomerID, ProductID, BranchID, AccountNo, Currency, OpenDate, CloseDate, Status, CreditLimit, UpdatedAt)
SELECT 900000 + n, 900000 + n, 1, 5, CONCAT('NB9', RIGHT('00000' + CAST(n AS VARCHAR(5)), 5), '-01'), 'EGP', '2024-06-01', NULL, 'Active', NULL, '2024-06-01'
FROM etl.Numbers WHERE n <= 25;

INSERT INTO src.AccountExtract (AccountID, CustomerID, ProductID, BranchID, AccountNo, Currency, OpenDate, CloseDate, Status, CreditLimit, UpdatedAt)
SELECT AccountID, CustomerID, ProductID, BranchID, AccountNo, Currency, OpenDate, CloseDate, Status, CreditLimit, UpdatedAt
FROM src.AccountExtract WHERE AccountID % 800 = 11;

/* ---------------------------------------------------------------- transactions */
IF OBJECT_ID('tempdb..#TxnAcct') IS NOT NULL DROP TABLE #TxnAcct;
SELECT Idx = ROW_NUMBER() OVER (ORDER BY a.AccountID),
       a.AccountID, a.CustomerID, p.ProductType, c.IncomeBand, c.Age, c.StopDate, a.OpenDate
INTO #TxnAcct
FROM src.AccountExtract a
JOIN src.ProductExtract p ON p.ProductID = a.ProductID
JOIN #Cust c ON c.CustomerID = a.CustomerID
WHERE a.Status IN ('Active','Dormant') AND p.ProductType IN ('Current','Savings','CreditCard')
  AND a.AccountID < 900000;
CREATE UNIQUE CLUSTERED INDEX ux_TxnAcct ON #TxnAcct (Idx);
DECLARE @TxnAcctCount INT = (SELECT COUNT(*) FROM #TxnAcct);

IF OBJECT_ID('tempdb..#Txn') IS NOT NULL DROP TABLE #Txn;
CREATE TABLE #Txn
(
    Seq INT IDENTITY(1,1) PRIMARY KEY,
    AccountID INT, TxnDate DATE, TxnTime TIME(0), TxnType VARCHAR(20), Channel VARCHAR(15),
    MerchantCategory VARCHAR(20), Amount DECIMAL(14,2), Description NVARCHAR(100)
);

/* A) salaries: employed customers, current account, monthly around the 25th */
INSERT INTO #Txn (AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description)
SELECT ta.AccountID,
       DATEFROMPARTS(2024 + (m.n - 1) / 12, ((m.n - 1) % 12) + 1, 24 + CAST(FLOOR(rD.v * 5) AS INT)),
       TIMEFROMPARTS(9 + CAST(FLOOR(rD.v * 3) AS INT), CAST(FLOOR(rA.v * 60) AS INT), 0, 0, 0),
       'Salary', 'System', NULL,
       ROUND(CASE ta.IncomeBand WHEN '<5k' THEN 4200 WHEN '5-15k' THEN 9500 WHEN '15-30k' THEN 21000 WHEN '30-60k' THEN 42000 ELSE 85000 END
             * (0.92 + rA.v * 0.16), 0),
       N'Monthly salary credit'
FROM #TxnAcct ta
JOIN #Cust c ON c.CustomerID = ta.CustomerID
CROSS JOIN (SELECT n FROM etl.Numbers WHERE n <= 24) AS m
CROSS APPLY etl.fn_Rnd('sal_day', ta.Idx * 100 + m.n) AS rD
CROSS APPLY etl.fn_Rnd('sal_amt', ta.Idx * 100 + m.n) AS rA
WHERE ta.ProductType = 'Current'
  AND c.EmploymentStatus = 'Employed'
  AND DATEFROMPARTS(2024 + (m.n - 1) / 12, ((m.n - 1) % 12) + 1, 1) >= ta.OpenDate
  AND (ta.StopDate IS NULL OR DATEFROMPARTS(2024 + (m.n - 1) / 12, ((m.n - 1) % 12) + 1, 1) < ta.StopDate);

PRINT CONCAT('salary transactions: ', @@ROWCOUNT);

/* B) everyday activity: card purchases, ATM, transfers, bills, fees, interest */
INSERT INTO #Txn (AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description)
SELECT
    ta.AccountID,
    d.TxnDate,
    TIMEFROMPARTS(CAST(CASE WHEN rH.v < 0.05 THEN 0 + FLOOR(rH.v * 140) WHEN rH.v < 0.5 THEN 8 + FLOOR((rH.v - 0.05) * 20) ELSE 17 + FLOOR((rH.v - 0.5) * 12) END AS INT) % 24,
                  CAST(FLOOR(rM.v * 60) AS INT), 0, 0, 0),
    t.TxnType,
    ch.Channel,
    CASE WHEN t.TxnType = 'CardPurchase'
         THEN CASE WHEN rMc.v < 0.30 THEN 'Groceries' WHEN rMc.v < 0.42 THEN 'Fuel' WHEN rMc.v < 0.57 THEN 'Restaurants'
                   WHEN rMc.v < 0.65 THEN 'Telecom' WHEN rMc.v < 0.71 THEN 'Utilities' WHEN rMc.v < 0.76 THEN 'Travel'
                   WHEN rMc.v < 0.82 THEN 'Electronics' WHEN rMc.v < 0.88 THEN 'Healthcare' WHEN rMc.v < 0.92 THEN 'Education'
                   ELSE 'Fashion' END END,
    amt.Amount,
    CASE t.TxnType WHEN 'CardPurchase' THEN N'Card purchase' WHEN 'ATMWithdrawal' THEN N'ATM cash withdrawal'
                   WHEN 'TransferOut' THEN N'Outgoing transfer' WHEN 'TransferIn' THEN N'Incoming transfer'
                   WHEN 'BillPayment' THEN N'Bill payment' WHEN 'Deposit' THEN N'Cash deposit'
                   WHEN 'Fee' THEN N'Service fee' WHEN 'Interest' THEN N'Interest credit' END
FROM (SELECT n FROM etl.Numbers WHERE n <= @RandomTxns) AS num
CROSS APPLY etl.fn_Rnd('t_acct', num.n) AS rAcc
JOIN #TxnAcct ta ON ta.Idx = CAST(1 + FLOOR(rAcc.v * @TxnAcctCount) AS BIGINT)
CROSS APPLY etl.fn_Rnd('t_date', num.n) AS rDt
CROSS APPLY etl.fn_Rnd('t_type', num.n) AS rT
CROSS APPLY etl.fn_Rnd('t_chan', num.n) AS rC
CROSS APPLY etl.fn_Rnd('t_amt',  num.n) AS rAm
CROSS APPLY etl.fn_Rnd('t_hour', num.n) AS rH
CROSS APPLY etl.fn_Rnd('t_min',  num.n) AS rM
CROSS APPLY etl.fn_Rnd('t_mcc',  num.n) AS rMc
CROSS APPLY (SELECT TxnDate = DATEADD(DAY, FLOOR(POWER(rDt.v, 0.85) * @WindowDays), @WindowStart)) AS d
CROSS APPLY
(
    SELECT TxnType =
        CASE ta.ProductType
            WHEN 'Current'    THEN CASE WHEN rT.v < 0.30 THEN 'CardPurchase' WHEN rT.v < 0.52 THEN 'ATMWithdrawal' WHEN rT.v < 0.67 THEN 'TransferOut'
                                        WHEN rT.v < 0.77 THEN 'TransferIn'   WHEN rT.v < 0.89 THEN 'BillPayment'   WHEN rT.v < 0.95 THEN 'Deposit' ELSE 'Fee' END
            WHEN 'Savings'    THEN CASE WHEN rT.v < 0.40 THEN 'Deposit'      WHEN rT.v < 0.65 THEN 'TransferIn'    WHEN rT.v < 0.85 THEN 'TransferOut'
                                        WHEN rT.v < 0.95 THEN 'Interest' ELSE 'Fee' END
            ELSE                   CASE WHEN rT.v < 0.80 THEN 'CardPurchase' WHEN rT.v < 0.88 THEN 'Fee' ELSE 'TransferIn' END
        END
) AS t
CROSS APPLY
(
    SELECT Channel =
        CASE t.TxnType
            WHEN 'CardPurchase'  THEN CASE WHEN rC.v < 0.68 THEN 'POS' ELSE 'Mobile' END
            WHEN 'ATMWithdrawal' THEN 'ATM'
            WHEN 'Deposit'       THEN CASE WHEN rC.v < 0.55 THEN 'Branch' ELSE 'ATM' END
            WHEN 'Fee'           THEN 'System'
            WHEN 'Interest'      THEN 'System'
            ELSE CASE WHEN ta.Age >= 55 THEN CASE WHEN rC.v < 0.35 THEN 'Mobile' WHEN rC.v < 0.50 THEN 'Internet' WHEN rC.v < 0.90 THEN 'Branch' ELSE 'CallCenter' END
                                       ELSE CASE WHEN rC.v < 0.60 THEN 'Mobile' WHEN rC.v < 0.85 THEN 'Internet' WHEN rC.v < 0.96 THEN 'Branch' ELSE 'CallCenter' END END
        END
) AS ch
CROSS APPLY
(
    SELECT Amount =
        CASE t.TxnType
            WHEN 'CardPurchase'  THEN -ROUND(50 + 2950 * POWER(rAm.v, 3), 2)
            WHEN 'ATMWithdrawal' THEN -100 * (2 + FLOOR(POWER(rAm.v, 2) * 48))
            WHEN 'TransferOut'   THEN -ROUND(200 + 49800 * POWER(rAm.v, 4), 2)
            WHEN 'BillPayment'   THEN -ROUND(100 + 2400 * POWER(rAm.v, 2), 2)
            WHEN 'Fee'           THEN -ROUND(10 + 140 * rAm.v, 2)
            WHEN 'TransferIn'    THEN  ROUND(200 + 49800 * POWER(rAm.v, 4), 2)
            WHEN 'Deposit'       THEN  ROUND(500 + 39500 * POWER(rAm.v, 3), 2)
            WHEN 'Interest'      THEN  ROUND(20 + 1480 * POWER(rAm.v, 2), 2)
        END
) AS amt
WHERE d.TxnDate >= ta.OpenDate
  AND (ta.StopDate IS NULL OR d.TxnDate < ta.StopDate);

PRINT CONCAT('everyday transactions: ', @@ROWCOUNT);

/* C) loan instalments: monthly debit on the 5th for lending products */
INSERT INTO #Txn (AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description)
SELECT a.AccountID,
       DATEFROMPARTS(2024 + (m.n - 1) / 12, ((m.n - 1) % 12) + 1, 5),
       TIMEFROMPARTS(6, 0, 0, 0, 0),
       'LoanInstalment', 'System', NULL,
       -ROUND(CASE p.ProductType WHEN 'PersonalLoan' THEN 1500 + 6500 * rI.v WHEN 'AutoLoan' THEN 4000 + 11000 * rI.v ELSE 6000 + 24000 * rI.v END, 0),
       N'Loan instalment'
FROM src.AccountExtract a
JOIN src.ProductExtract p ON p.ProductID = a.ProductID
CROSS JOIN (SELECT n FROM etl.Numbers WHERE n <= 24) AS m
CROSS APPLY etl.fn_Rnd('loan_amt', a.AccountID) AS rI
WHERE p.ProductType IN ('PersonalLoan','AutoLoan','Mortgage') AND a.Status = 'Active' AND a.AccountID < 900000
  AND DATEFROMPARTS(2024 + (m.n - 1) / 12, ((m.n - 1) % 12) + 1, 5) >= a.OpenDate;

PRINT CONCAT('loan instalments: ', @@ROWCOUNT);

/* materialise into the landing table with ids and the watermark column */
INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 1000000000 + ROW_NUMBER() OVER (ORDER BY TxnDate, TxnTime, Seq),
       AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description,
       DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00:00' AS TIME(0)), TxnTime) + 60 * (1 + Seq % 7), CAST(TxnDate AS DATETIME2(0)))
FROM #Txn;

PRINT CONCAT('transactions landed: ', @@ROWCOUNT);

/* planted defects ------------------------------------------------------------
   a) 500 exact duplicates (re-sent file)   b) 100 future-dated rows
   c) 50 rows with NULL AccountID           d) 40 rows pointing at unknown accounts
   e) 20 rows with NULL amount
*/
INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT TOP (500) TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt
FROM src.TransactionExtract WHERE TransactionID % 1979 = 0 ORDER BY TransactionID;

INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 1900000000 + n, ta.AccountID, DATEADD(DAY, n, '2031-01-01'), '12:00', 'Deposit', 'Branch', NULL, 1000.00, N'Future-dated row (defect)', '2025-12-31 23:00'
FROM etl.Numbers CROSS APPLY (SELECT TOP (1) AccountID FROM #TxnAcct WHERE Idx = n) ta WHERE n <= 100;

INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 1900001000 + n, NULL, '2025-11-15', '10:00', 'Fee', 'System', NULL, -25.00, N'Missing account (defect)', '2025-11-15 10:05'
FROM etl.Numbers WHERE n <= 50;

INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 1900002000 + n, 9990000 + n, '2025-11-16', '10:00', 'Deposit', 'Branch', NULL, 500.00, N'Unknown account (defect)', '2025-11-16 10:05'
FROM etl.Numbers WHERE n <= 40;

INSERT INTO src.TransactionExtract (TransactionID, AccountID, TxnDate, TxnTime, TxnType, Channel, MerchantCategory, Amount, Description, CreatedAt)
SELECT 1900003000 + n, ta.AccountID, '2025-11-17', '10:00', 'Fee', 'System', NULL, NULL, N'Missing amount (defect)', '2025-11-17 10:05'
FROM etl.Numbers CROSS APPLY (SELECT TOP (1) AccountID FROM #TxnAcct WHERE Idx = n + 500) ta WHERE n <= 20;

/* ---------------------------------------------------------------- complaints */
INSERT INTO src.ComplaintExtract (ComplaintID, CustomerID, OpenedDate, ClosedDate, Category, Channel, Severity, Status)
SELECT 5000000 + ROW_NUMBER() OVER (ORDER BY c.CustomerID, k.n),
       c.CustomerID,
       x.OpenedDate,
       CASE WHEN x.Status = 'Resolved' THEN DATEADD(DAY, CASE x.Severity WHEN 'High' THEN 5 + FLOOR(rR.v * 40) WHEN 'Medium' THEN 2 + FLOOR(rR.v * 20) ELSE FLOOR(rR.v * 10) END, x.OpenedDate) END,
       CASE WHEN rCat.v < 0.24 THEN 'Fees' WHEN rCat.v < 0.44 THEN 'CardIssue' WHEN rCat.v < 0.60 THEN 'AppOutage'
            WHEN rCat.v < 0.78 THEN 'ServiceQuality' WHEN rCat.v < 0.86 THEN 'Fraud' WHEN rCat.v < 0.94 THEN 'LoanTerms' ELSE 'Other' END,
       CASE WHEN rCh.v < 0.45 THEN 'CallCenter' WHEN rCh.v < 0.75 THEN 'Branch' WHEN rCh.v < 0.95 THEN 'Mobile' ELSE 'Internet' END,
       x.Severity,
       x.Status
FROM #Cust c
CROSS JOIN (SELECT n FROM etl.Numbers WHERE n <= 3) AS k          -- up to 3 complaints per customer
CROSS APPLY etl.fn_Rnd('cmp_has', c.CustomerID * 10 + k.n) AS rHas
CROSS APPLY etl.fn_Rnd('cmp_dt',  c.CustomerID * 10 + k.n) AS rDt
CROSS APPLY etl.fn_Rnd('cmp_cat', c.CustomerID * 10 + k.n) AS rCat
CROSS APPLY etl.fn_Rnd('cmp_ch',  c.CustomerID * 10 + k.n) AS rCh
CROSS APPLY etl.fn_Rnd('cmp_sev', c.CustomerID * 10 + k.n) AS rSev
CROSS APPLY etl.fn_Rnd('cmp_st',  c.CustomerID * 10 + k.n) AS rSt
CROSS APPLY etl.fn_Rnd('cmp_res', c.CustomerID * 10 + k.n) AS rR
CROSS APPLY
(
    SELECT OpenedDate = CASE WHEN c.StopDate IS NOT NULL
                             THEN DATEADD(DAY, -FLOOR(rDt.v * 120), c.StopDate)          -- attriters complain shortly before leaving
                             ELSE DATEADD(DAY, FLOOR(rDt.v * @WindowDays), @WindowStart) END,
           Severity   = CASE WHEN rSev.v < 0.55 THEN 'Low' WHEN rSev.v < 0.88 THEN 'Medium' ELSE 'High' END,
           Status     = CASE WHEN rSt.v < 0.84 THEN 'Resolved' WHEN rSt.v < 0.95 THEN 'Open' ELSE 'Escalated' END
) AS x
WHERE rHas.v < CASE WHEN c.StopDate IS NOT NULL THEN 0.28 ELSE 0.075 END    -- attriters complain ~4x more
  AND x.OpenedDate BETWEEN @WindowStart AND @WindowEnd;

PRINT CONCAT('complaints generated: ', @@ROWCOUNT);

/* ---------------------------------------------------------------- summary */
SELECT 'src.CustomerExtract'    AS TableName, COUNT(*) AS Rows_ FROM src.CustomerExtract
UNION ALL SELECT 'src.AccountExtract',     COUNT(*) FROM src.AccountExtract
UNION ALL SELECT 'src.TransactionExtract', COUNT(*) FROM src.TransactionExtract
UNION ALL SELECT 'src.ComplaintExtract',   COUNT(*) FROM src.ComplaintExtract
UNION ALL SELECT 'src.BranchExtract',      COUNT(*) FROM src.BranchExtract
UNION ALL SELECT 'src.ProductExtract',     COUNT(*) FROM src.ProductExtract;

/* temp tables are dropped so the script can be re-run in the same session */
DROP TABLE #Txn; DROP TABLE #TxnAcct; DROP TABLE #Acct; DROP TABLE #Cust;
DROP TABLE #FirstNames; DROP TABLE #LastNames; DROP TABLE #Geo;

PRINT CONCAT('02_generate_source_data.sql completed in ', DATEDIFF(SECOND, @t0, SYSUTCDATETIME()), ' seconds.');
GO
