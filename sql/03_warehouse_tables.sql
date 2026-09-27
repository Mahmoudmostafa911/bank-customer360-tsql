SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
/* =============================================================================
   03 · Warehouse tables: staging, dimensions, facts, audit, serving
   -----------------------------------------------------------------------------
   Kimball star schema.  Conventions:
     *Key     surrogate integer keys (identity), -1 = unknown member
     *ID      business keys from the source system (kept for traceability)
     RowHash  SHA2_256 of the tracked attributes → cheap change detection
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

/* ============================ STAGING (stg) ================================ */
IF OBJECT_ID(N'stg.Customer', N'U') IS NOT NULL DROP TABLE stg.Customer;
CREATE TABLE stg.Customer
(
    CustomerID        INT            NOT NULL CONSTRAINT PK_stg_Customer PRIMARY KEY CLUSTERED,
    FullName          NVARCHAR(121)  NOT NULL,
    Gender            VARCHAR(7)     NOT NULL,      -- Male / Female / Unknown
    BirthDate         DATE           NULL,
    Segment           VARCHAR(20)    NOT NULL,
    City              NVARCHAR(60)   NOT NULL,
    Governorate       NVARCHAR(60)   NOT NULL,
    EmploymentStatus  VARCHAR(20)    NOT NULL,
    IncomeBand        VARCHAR(20)    NOT NULL,
    RiskRating        VARCHAR(10)    NOT NULL,
    KYCStatus         VARCHAR(12)    NOT NULL,
    OnboardDate       DATE           NOT NULL,
    SourceUpdatedAt   DATETIME2(0)   NOT NULL,
    RowHash           BINARY(32)     NOT NULL
);

IF OBJECT_ID(N'stg.Account', N'U') IS NOT NULL DROP TABLE stg.Account;
CREATE TABLE stg.Account
(
    AccountID     INT            NOT NULL CONSTRAINT PK_stg_Account PRIMARY KEY CLUSTERED,
    CustomerID    INT            NOT NULL,
    ProductID     INT            NOT NULL,
    BranchID      INT            NOT NULL,
    AccountNo     VARCHAR(20)    NOT NULL,
    Currency      CHAR(3)        NOT NULL,
    OpenDate      DATE           NOT NULL,
    CloseDate     DATE           NULL,
    Status        VARCHAR(12)    NOT NULL,
    CreditLimit   DECIMAL(14,2)  NULL,
    SourceUpdatedAt DATETIME2(0) NOT NULL,
    RowHash       BINARY(32)     NOT NULL
);

IF OBJECT_ID(N'stg.[Transaction]', N'U') IS NOT NULL DROP TABLE stg.[Transaction];
CREATE TABLE stg.[Transaction]
(
    TransactionID    BIGINT         NOT NULL CONSTRAINT PK_stg_Transaction PRIMARY KEY CLUSTERED,
    AccountID        INT            NOT NULL,
    TxnDate          DATE           NOT NULL,
    TxnTime          TIME(0)        NOT NULL,
    TxnType          VARCHAR(20)    NOT NULL,
    Channel          VARCHAR(15)    NOT NULL,
    MerchantCategory VARCHAR(20)    NULL,
    Amount           DECIMAL(14,2)  NOT NULL,
    CreatedAt        DATETIME2(0)   NOT NULL
);

IF OBJECT_ID(N'stg.Rejected', N'U') IS NOT NULL DROP TABLE stg.Rejected;
CREATE TABLE stg.Rejected
(
    RejectID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_stg_Rejected PRIMARY KEY CLUSTERED,
    LoadID       INT               NOT NULL,
    SourceTable  SYSNAME           NOT NULL,
    SourceKey    NVARCHAR(50)      NULL,
    Reason       VARCHAR(100)      NOT NULL,
    RowPayload   NVARCHAR(MAX)     NULL,      -- the offending row as JSON, for triage
    RejectedAt   DATETIME2(0)      NOT NULL CONSTRAINT DF_stg_Rejected_RejectedAt DEFAULT SYSUTCDATETIME()
);
CREATE NONCLUSTERED INDEX IX_stg_Rejected_Load ON stg.Rejected (LoadID, SourceTable, Reason);
GO

/* ============================ DIMENSIONS (dim) ============================= */
IF OBJECT_ID(N'fact.[Transaction]', N'U')          IS NOT NULL DROP TABLE fact.[Transaction];
IF OBJECT_ID(N'fact.AccountMonthSnapshot', N'U') IS NOT NULL DROP TABLE fact.AccountMonthSnapshot;
IF OBJECT_ID(N'fact.Complaint', N'U')            IS NOT NULL DROP TABLE fact.Complaint;
IF OBJECT_ID(N'rpt.Customer360', N'U')           IS NOT NULL DROP TABLE rpt.Customer360;
IF OBJECT_ID(N'dim.Account', N'U')               IS NOT NULL DROP TABLE dim.Account;
IF OBJECT_ID(N'dim.Customer', N'U')              IS NOT NULL DROP TABLE dim.Customer;
IF OBJECT_ID(N'dim.Product', N'U')               IS NOT NULL DROP TABLE dim.Product;
IF OBJECT_ID(N'dim.Branch', N'U')                IS NOT NULL DROP TABLE dim.Branch;
IF OBJECT_ID(N'dim.Channel', N'U')               IS NOT NULL DROP TABLE dim.Channel;
IF OBJECT_ID(N'dim.TransactionType', N'U')       IS NOT NULL DROP TABLE dim.TransactionType;
IF OBJECT_ID(N'dim.Date', N'U')                  IS NOT NULL DROP TABLE dim.Date;
GO

CREATE TABLE dim.Date
(
    DateKey        INT          NOT NULL CONSTRAINT PK_dim_Date PRIMARY KEY CLUSTERED,   -- yyyymmdd
    FullDate       DATE         NOT NULL CONSTRAINT UQ_dim_Date_FullDate UNIQUE,
    DayOfMonth     TINYINT      NOT NULL,
    DayName        VARCHAR(9)   NOT NULL,
    IsWeekend      BIT          NOT NULL,          -- Egyptian weekend: Friday & Saturday
    MonthKey       INT          NOT NULL,          -- yyyymm
    MonthNumber    TINYINT      NOT NULL,
    MonthName      VARCHAR(9)   NOT NULL,
    MonthStartDate DATE         NOT NULL,
    MonthEndDate   DATE         NOT NULL,
    QuarterNumber  TINYINT      NOT NULL,
    QuarterLabel   CHAR(6)      NOT NULL,          -- '2025Q1'
    CalendarYear   SMALLINT     NOT NULL,
    FiscalYear     SMALLINT     NOT NULL,          -- July–June, labelled by the year it ends in
    FiscalQuarter  TINYINT      NOT NULL,
    IsLastDayOfMonth BIT        NOT NULL
);

CREATE TABLE dim.Product
(
    ProductKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_Product PRIMARY KEY CLUSTERED,
    ProductID      INT            NOT NULL CONSTRAINT UQ_dim_Product_ProductID UNIQUE,
    ProductCode    VARCHAR(10)    NOT NULL,
    ProductName    NVARCHAR(80)   NOT NULL,
    ProductType    VARCHAR(20)    NOT NULL,
    ProductFamily  VARCHAR(10)    NOT NULL,   -- Deposit / Lending
    IsLiability    BIT            NOT NULL,
    AnnualRatePct  DECIMAL(5,2)   NULL
);

CREATE TABLE dim.Branch
(
    BranchKey    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_Branch PRIMARY KEY CLUSTERED,
    BranchID     INT            NOT NULL CONSTRAINT UQ_dim_Branch_BranchID UNIQUE,
    BranchCode   VARCHAR(10)    NOT NULL,
    BranchName   NVARCHAR(80)   NOT NULL,
    City         NVARCHAR(60)   NOT NULL,
    Governorate  NVARCHAR(60)   NOT NULL,
    Region       VARCHAR(30)    NOT NULL,
    OpenedYear   SMALLINT       NULL
);

CREATE TABLE dim.Channel
(
    ChannelKey   INT           NOT NULL CONSTRAINT PK_dim_Channel PRIMARY KEY CLUSTERED,
    ChannelName  VARCHAR(15)   NOT NULL CONSTRAINT UQ_dim_Channel_Name UNIQUE,
    ChannelGroup VARCHAR(10)   NOT NULL,   -- Digital / Assisted / SelfService / System
    IsDigital    BIT           NOT NULL
);

CREATE TABLE dim.TransactionType
(
    TxnTypeKey   INT           NOT NULL CONSTRAINT PK_dim_TransactionType PRIMARY KEY CLUSTERED,
    TxnType      VARCHAR(20)   NOT NULL CONSTRAINT UQ_dim_TransactionType_Type UNIQUE,
    Direction    VARCHAR(6)    NOT NULL,   -- Credit / Debit
    TxnGroup     VARCHAR(12)   NOT NULL,   -- Income / Spending / Cash / Transfer / Charges / Lending
    IsRevenueForBank BIT       NOT NULL    -- fees & interest income lines
);

CREATE TABLE dim.Customer
(
    CustomerKey      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_Customer PRIMARY KEY CLUSTERED,
    CustomerID       INT            NOT NULL,
    FullName         NVARCHAR(121)  NOT NULL,
    Gender           VARCHAR(7)     NOT NULL,
    BirthDate        DATE           NULL,
    AgeBand          VARCHAR(8)     NOT NULL,   -- derived at load time from BirthDate
    Segment          VARCHAR(20)    NOT NULL,
    City             NVARCHAR(60)   NOT NULL,
    Governorate      NVARCHAR(60)   NOT NULL,
    EmploymentStatus VARCHAR(20)    NOT NULL,
    IncomeBand       VARCHAR(20)    NOT NULL,
    RiskRating       VARCHAR(10)    NOT NULL,
    KYCStatus        VARCHAR(12)    NOT NULL,
    OnboardDate      DATE           NOT NULL,
    -- SCD Type 2 bookkeeping
    ValidFrom        DATETIME2(0)   NOT NULL,
    ValidTo          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_Customer_ValidTo DEFAULT '9999-12-31',
    IsCurrent        BIT            NOT NULL CONSTRAINT DF_dim_Customer_IsCurrent DEFAULT 1,
    RowHash          BINARY(32)     NOT NULL,
    LoadID           INT            NULL,
    CONSTRAINT CK_dim_Customer_Validity CHECK (ValidFrom < ValidTo)
);
-- exactly one current version per business key (enforced, not just hoped for)
CREATE UNIQUE NONCLUSTERED INDEX UX_dim_Customer_Current ON dim.Customer (CustomerID) WHERE IsCurrent = 1;
-- point-in-time lookups: which version was valid on a given transaction date?
CREATE NONCLUSTERED INDEX IX_dim_Customer_History ON dim.Customer (CustomerID, ValidFrom, ValidTo) INCLUDE (CustomerKey);

CREATE TABLE dim.Account
(
    AccountKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_Account PRIMARY KEY CLUSTERED,
    AccountID      INT            NOT NULL CONSTRAINT UQ_dim_Account_AccountID UNIQUE,
    AccountNo      VARCHAR(20)    NOT NULL,
    CustomerID     INT            NOT NULL,
    ProductKey     INT            NOT NULL CONSTRAINT FK_dim_Account_Product REFERENCES dim.Product (ProductKey),
    BranchKey      INT            NOT NULL CONSTRAINT FK_dim_Account_Branch  REFERENCES dim.Branch (BranchKey),
    Currency       CHAR(3)        NOT NULL,
    OpenDate       DATE           NOT NULL,
    CloseDate      DATE           NULL,
    Status         VARCHAR(12)    NOT NULL,
    IsOpen         AS CAST(CASE WHEN Status IN ('Active','Dormant','Frozen') THEN 1 ELSE 0 END AS BIT) PERSISTED,
    CreditLimit    DECIMAL(14,2)  NULL,
    RowHash        BINARY(32)     NOT NULL,
    LoadID         INT            NULL
);
CREATE NONCLUSTERED INDEX IX_dim_Account_Customer ON dim.Account (CustomerID) INCLUDE (AccountKey, ProductKey, Status);
GO

/* ------------------------------- unknown members ---------------------------- */
SET IDENTITY_INSERT dim.Product ON;
INSERT INTO dim.Product (ProductKey, ProductID, ProductCode, ProductName, ProductType, ProductFamily, IsLiability, AnnualRatePct)
VALUES (-1, -1, 'UNK', N'Unknown', 'Unknown', 'Unknown', 0, NULL);
SET IDENTITY_INSERT dim.Product OFF;

SET IDENTITY_INSERT dim.Branch ON;
INSERT INTO dim.Branch (BranchKey, BranchID, BranchCode, BranchName, City, Governorate, Region, OpenedYear)
VALUES (-1, -1, 'UNK', N'Unknown', N'Unknown', N'Unknown', 'Unknown', NULL);
SET IDENTITY_INSERT dim.Branch OFF;

SET IDENTITY_INSERT dim.Customer ON;
INSERT INTO dim.Customer (CustomerKey, CustomerID, FullName, Gender, BirthDate, AgeBand, Segment, City, Governorate, EmploymentStatus,
                          IncomeBand, RiskRating, KYCStatus, OnboardDate, ValidFrom, ValidTo, IsCurrent, RowHash)
VALUES (-1, -1, N'Unknown', 'Unknown', NULL, 'Unknown', 'Unknown', N'Unknown', N'Unknown', 'Unknown',
        'Unknown', 'Unknown', 'Unknown', '1900-01-01', '1900-01-01', '9999-12-31', 1, 0x00);
SET IDENTITY_INSERT dim.Customer OFF;

SET IDENTITY_INSERT dim.Account ON;
INSERT INTO dim.Account (AccountKey, AccountID, AccountNo, CustomerID, ProductKey, BranchKey, Currency, OpenDate, CloseDate, Status, CreditLimit, RowHash)
VALUES (-1, -1, 'UNKNOWN', -1, -1, -1, 'EGP', '1900-01-01', NULL, 'Unknown', NULL, 0x00);
SET IDENTITY_INSERT dim.Account OFF;

INSERT INTO dim.Channel (ChannelKey, ChannelName, ChannelGroup, IsDigital)
VALUES (-1, 'Unknown', 'Unknown', 0),
       (1, 'Mobile',     'Digital',     1),
       (2, 'Internet',   'Digital',     1),
       (3, 'ATM',        'SelfService', 0),
       (4, 'POS',        'SelfService', 0),
       (5, 'Branch',     'Assisted',    0),
       (6, 'CallCenter', 'Assisted',    0),
       (7, 'System',     'System',      0);

INSERT INTO dim.TransactionType (TxnTypeKey, TxnType, Direction, TxnGroup, IsRevenueForBank)
VALUES (-1, 'Unknown',        'Debit',  'Unknown',  0),
       (1, 'Salary',          'Credit', 'Income',   0),
       (2, 'Deposit',         'Credit', 'Cash',     0),
       (3, 'TransferIn',      'Credit', 'Transfer', 0),
       (4, 'Interest',        'Credit', 'Charges',  0),
       (5, 'CardPurchase',    'Debit',  'Spending', 0),
       (6, 'ATMWithdrawal',   'Debit',  'Cash',     0),
       (7, 'TransferOut',     'Debit',  'Transfer', 0),
       (8, 'BillPayment',     'Debit',  'Spending', 0),
       (9, 'Fee',             'Debit',  'Charges',  1),
       (10,'LoanInstalment',  'Debit',  'Lending',  1);
GO

/* ============================ FACTS (fact) ================================= */
CREATE TABLE fact.[Transaction]
(
    TransactionKey   BIGINT IDENTITY(1,1) NOT NULL,
    TransactionID    BIGINT         NOT NULL,          -- degenerate dimension / idempotency key
    DateKey          INT            NOT NULL,
    TxnTime          TIME(0)        NOT NULL,
    AccountKey       INT            NOT NULL,
    CustomerKey      INT            NOT NULL,          -- SCD2 version valid on the transaction date
    ProductKey       INT            NOT NULL,
    BranchKey        INT            NOT NULL,
    ChannelKey       INT            NOT NULL,
    TxnTypeKey       INT            NOT NULL,
    MerchantCategory VARCHAR(20)    NULL,
    Amount           DECIMAL(14,2)  NOT NULL,          -- signed: credits > 0, debits < 0
    IsCredit         BIT            NOT NULL,          -- stored (not computed) — computed columns are not allowed with a clustered columnstore index
    LoadID           INT            NOT NULL
);
-- Columnstore: analytics scans over a million rows in milliseconds and compresses ~10x.
CREATE CLUSTERED COLUMNSTORE INDEX CCI_fact_Transaction ON fact.[Transaction];
-- Rowstore uniqueness index so the incremental load can reject re-sent rows cheaply.
CREATE UNIQUE NONCLUSTERED INDEX UX_fact_Transaction_TransactionID ON fact.[Transaction] (TransactionID);
CREATE NONCLUSTERED INDEX IX_fact_Transaction_Account_Date ON fact.[Transaction] (AccountKey, DateKey) INCLUDE (Amount);

CREATE TABLE fact.AccountMonthSnapshot
(
    MonthKey          INT            NOT NULL,
    AccountKey        INT            NOT NULL,
    CustomerKey       INT            NOT NULL,          -- current version at month end
    ProductKey        INT            NOT NULL,
    OpeningBalance    DECIMAL(16,2)  NOT NULL,
    ClosingBalance    DECIMAL(16,2)  NOT NULL,
    TxnCount          INT            NOT NULL,
    CreditAmount      DECIMAL(16,2)  NOT NULL,
    DebitAmount       DECIMAL(16,2)  NOT NULL,
    FeeAmount         DECIMAL(16,2)  NOT NULL,
    DigitalTxnCount   INT            NOT NULL,
    LastTxnDate       DATE           NULL,
    DaysSinceLastTxn  INT            NULL,              -- as of month end
    IsDormant3M       BIT            NOT NULL,          -- no transactions this month or the previous two
    IsOpen            BIT            NOT NULL,
    LoadID            INT            NOT NULL,
    CONSTRAINT PK_fact_AccountMonthSnapshot PRIMARY KEY CLUSTERED (MonthKey, AccountKey)
);
CREATE NONCLUSTERED INDEX IX_fact_AccountMonthSnapshot_Customer ON fact.AccountMonthSnapshot (CustomerKey, MonthKey) INCLUDE (ClosingBalance, TxnCount, IsDormant3M);

CREATE TABLE fact.Complaint
(
    ComplaintKey    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_Complaint PRIMARY KEY CLUSTERED,
    ComplaintID     INT            NOT NULL CONSTRAINT UQ_fact_Complaint_ComplaintID UNIQUE,
    CustomerKey     INT            NOT NULL,
    OpenedDateKey   INT            NOT NULL,
    ClosedDateKey   INT            NULL,
    Category        VARCHAR(30)    NOT NULL,
    Channel         VARCHAR(15)    NOT NULL,
    Severity        VARCHAR(8)     NOT NULL,
    Status          VARCHAR(12)    NOT NULL,
    ResolutionDays  INT            NULL,
    IsResolved      AS CAST(CASE WHEN Status = 'Resolved' THEN 1 ELSE 0 END AS BIT) PERSISTED,
    LoadID          INT            NOT NULL
);
CREATE NONCLUSTERED INDEX IX_fact_Complaint_Customer ON fact.Complaint (CustomerKey, OpenedDateKey);
GO

/* ============================ AUDIT (audit) ================================ */
IF OBJECT_ID(N'audit.DataQualityResult', N'U') IS NULL
CREATE TABLE audit.DataQualityResult
(
    ResultID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_DataQualityResult PRIMARY KEY CLUSTERED,
    LoadID       INT            NOT NULL,
    CheckName    VARCHAR(80)    NOT NULL,
    Severity     VARCHAR(5)     NOT NULL,   -- FAIL blocks the load, WARN is reported, INFO is context
    Status       VARCHAR(4)     NOT NULL,   -- PASS / WARN / FAIL
    Observed     DECIMAL(18,2)  NULL,
    Expected     VARCHAR(60)    NULL,
    Details      NVARCHAR(400)  NULL,
    CheckedAt    DATETIME2(0)   NOT NULL CONSTRAINT DF_audit_DQ_CheckedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_audit_DQ_Severity CHECK (Severity IN ('FAIL','WARN','INFO')),
    CONSTRAINT CK_audit_DQ_Status   CHECK (Status IN ('PASS','WARN','FAIL'))
);
GO

/* ============================ SERVING (rpt) ================================ */
CREATE TABLE rpt.Customer360
(
    CustomerKey          INT            NOT NULL CONSTRAINT PK_rpt_Customer360 PRIMARY KEY CLUSTERED,
    CustomerID           INT            NOT NULL,
    FullName             NVARCHAR(121)  NOT NULL,
    Segment              VARCHAR(20)    NOT NULL,
    Governorate          NVARCHAR(60)   NOT NULL,
    AgeBand              VARCHAR(8)     NOT NULL,
    IncomeBand           VARCHAR(20)    NOT NULL,
    TenureMonths         INT            NOT NULL,
    TenureBand           VARCHAR(10)    NOT NULL,
    ProductsHeld         TINYINT        NOT NULL,
    HasCurrent           BIT NOT NULL, HasSavings BIT NOT NULL, HasFixedDeposit BIT NOT NULL,
    HasCreditCard        BIT NOT NULL, HasLoan    BIT NOT NULL,
    TotalDepositBalance  DECIMAL(16,2)  NOT NULL,   -- sum of closing balances on deposit products (latest month)
    MonthlyTxnAvg        DECIMAL(9,2)   NOT NULL,   -- last 12 months
    MonthlySpendAvg      DECIMAL(16,2)  NOT NULL,   -- debits on spending group, last 12 months
    DigitalTxnPct        DECIMAL(5,1)   NULL,       -- share of Mobile+Internet transactions, last 12 months
    LastTxnDate          DATE           NULL,
    DaysSinceLastTxn     INT            NULL,
    ComplaintsLast12M    TINYINT        NOT NULL,
    OpenComplaints       TINYINT        NOT NULL,
    RecencyScore         TINYINT        NOT NULL,   -- 1..5 (5 = most recent)
    FrequencyScore       TINYINT        NOT NULL,
    MonetaryScore        TINYINT        NOT NULL,
    RFMSegment           VARCHAR(20)    NOT NULL,
    IsChurned            BIT            NOT NULL,   -- no transaction in 90+ days and no open lending
    ChurnRiskBand        VARCHAR(8)     NOT NULL,   -- Low / Medium / High (rule-based, explainable)
    ChurnRiskReasons     VARCHAR(200)   NULL,
    SnapshotDate         DATE           NOT NULL,
    RefreshedAt          DATETIME2(0)   NOT NULL CONSTRAINT DF_rpt_Customer360_RefreshedAt DEFAULT SYSUTCDATETIME()
);
CREATE NONCLUSTERED INDEX IX_rpt_Customer360_Segments ON rpt.Customer360 (Segment, RFMSegment, ChurnRiskBand) INCLUDE (TotalDepositBalance, IsChurned);
GO

PRINT '03_warehouse_tables.sql completed: stg (4), dim (7), fact (3), audit (1), rpt (1).';
GO
