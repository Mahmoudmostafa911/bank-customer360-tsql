/* =============================================================================
   01 · Source landing tables (schema src)
   -----------------------------------------------------------------------------
   These simulate flat extracts landed from a core-banking system: no primary
   keys, no foreign keys, loosely typed text columns — exactly the shape a data
   engineer receives, including the defects the staging layer has to deal with.
   ============================================================================= */
USE BankDW;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'src.CustomerExtract', N'U') IS NOT NULL DROP TABLE src.CustomerExtract;
CREATE TABLE src.CustomerExtract
(
    CustomerID        INT            NULL,
    FirstName         NVARCHAR(60)   NULL,
    LastName          NVARCHAR(60)   NULL,
    Gender            VARCHAR(10)    NULL,   -- 'M','F','Male','female', ...
    BirthDate         VARCHAR(12)    NULL,   -- text in the extract: 'YYYY-MM-DD' (a few malformed)
    Segment           VARCHAR(20)    NULL,   -- Retail / Affluent / SME / Private
    City              NVARCHAR(60)   NULL,   -- dirty: mixed case, padded spaces
    Governorate       NVARCHAR(60)   NULL,
    EmploymentStatus  VARCHAR(20)    NULL,
    IncomeBand        VARCHAR(20)    NULL,   -- '<5k','5-15k','15-30k','30-60k','60k+'
    RiskRating        VARCHAR(10)    NULL,
    KYCStatus         VARCHAR(12)    NULL,
    OnboardDate       DATE           NULL,
    UpdatedAt         DATETIME2(0)   NULL,
    ExtractedAt       DATETIME2(0)   NOT NULL CONSTRAINT DF_src_CustomerExtract_ExtractedAt DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID(N'src.BranchExtract', N'U') IS NOT NULL DROP TABLE src.BranchExtract;
CREATE TABLE src.BranchExtract
(
    BranchID      INT           NULL,
    BranchCode    VARCHAR(10)   NULL,
    BranchName    NVARCHAR(80)  NULL,
    City          NVARCHAR(60)  NULL,
    Governorate   NVARCHAR(60)  NULL,
    Region        VARCHAR(30)   NULL,
    OpenedYear    SMALLINT      NULL
);

IF OBJECT_ID(N'src.ProductExtract', N'U') IS NOT NULL DROP TABLE src.ProductExtract;
CREATE TABLE src.ProductExtract
(
    ProductID     INT           NULL,
    ProductCode   VARCHAR(10)   NULL,
    ProductName   NVARCHAR(80)  NULL,
    ProductType   VARCHAR(20)   NULL,   -- Current / Savings / FixedDeposit / CreditCard / PersonalLoan / Mortgage / AutoLoan
    IsLiability   BIT           NULL,   -- 1 = deposit product (bank owes customer), 0 = lending
    AnnualRatePct DECIMAL(5,2)  NULL
);

IF OBJECT_ID(N'src.AccountExtract', N'U') IS NOT NULL DROP TABLE src.AccountExtract;
CREATE TABLE src.AccountExtract
(
    AccountID     INT           NULL,
    CustomerID    INT           NULL,
    ProductID     INT           NULL,
    BranchID      INT           NULL,
    AccountNo     VARCHAR(20)   NULL,
    Currency      CHAR(3)       NULL,
    OpenDate      DATE          NULL,
    CloseDate     DATE          NULL,
    Status        VARCHAR(12)   NULL,   -- Active / Dormant / Closed / Frozen
    CreditLimit   DECIMAL(14,2) NULL,
    UpdatedAt     DATETIME2(0)  NULL
);

IF OBJECT_ID(N'src.TransactionExtract', N'U') IS NOT NULL DROP TABLE src.TransactionExtract;
CREATE TABLE src.TransactionExtract
(
    TransactionID   BIGINT        NULL,
    AccountID       INT           NULL,
    TxnDate         DATE          NULL,
    TxnTime         TIME(0)       NULL,
    TxnType         VARCHAR(20)   NULL,   -- Salary / Deposit / CardPurchase / ATMWithdrawal / TransferOut / TransferIn / BillPayment / Fee / Interest / LoanInstalment
    Channel         VARCHAR(15)   NULL,   -- Mobile / Internet / ATM / POS / Branch / CallCenter
    MerchantCategory VARCHAR(20)  NULL,   -- only for card purchases
    Amount          DECIMAL(14,2) NULL,   -- signed: credits > 0, debits < 0
    Description     NVARCHAR(100) NULL,
    CreatedAt       DATETIME2(0)  NULL    -- system timestamp used as the incremental watermark
);

IF OBJECT_ID(N'src.ComplaintExtract', N'U') IS NOT NULL DROP TABLE src.ComplaintExtract;
CREATE TABLE src.ComplaintExtract
(
    ComplaintID   INT           NULL,
    CustomerID    INT           NULL,
    OpenedDate    DATE          NULL,
    ClosedDate    DATE          NULL,
    Category      VARCHAR(30)   NULL,   -- Fees / CardIssue / AppOutage / ServiceQuality / Fraud / LoanTerms / Other
    Channel       VARCHAR(15)   NULL,
    Severity      VARCHAR(8)    NULL,   -- Low / Medium / High
    Status        VARCHAR(12)   NULL    -- Open / Resolved / Escalated
);
GO

/* Heaps are fine for landing tables, but a nonclustered index on the watermark
   column makes the incremental fact load a cheap range scan. */
CREATE NONCLUSTERED INDEX IX_src_TransactionExtract_CreatedAt ON src.TransactionExtract (CreatedAt) INCLUDE (TransactionID);
GO

PRINT '01_source_extracts.sql completed: 6 landing tables in schema src.';
GO
