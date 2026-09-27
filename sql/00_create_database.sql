/* =============================================================================
   Bank Customer 360 & Churn Warehouse  —  00 · database, schemas, utilities
   -----------------------------------------------------------------------------
   Target : SQL Server 2017+ (Express/Developer/Standard) or Azure SQL Database
   Run in : SSMS, one script at a time in numeric order, or sql/run_all.sql in
            SQLCMD mode.  Every script is re-runnable (idempotent).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_ID(N'BankDW') IS NULL
BEGIN
    CREATE DATABASE BankDW;
END
GO

USE BankDW;
GO

-- Simple recovery keeps the log small while we generate ~1M synthetic rows.
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'BankDW') <> N'SIMPLE'
   AND SERVERPROPERTY('EngineEdition') <> 5      -- not allowed on Azure SQL Database
    ALTER DATABASE BankDW SET RECOVERY SIMPLE;
GO

/* ---------- schemas ---------------------------------------------------------
   src   : landing extracts from the (simulated) core-banking system, no constraints
   stg   : cleansed, typed, de-duplicated staging
   dim   : conformed dimensions               fact : fact tables
   etl   : load framework (log, watermark, helpers)
   audit : data-quality results               rpt  : serving layer (Customer 360, views)
   test  : assertion framework
   --------------------------------------------------------------------------- */
DECLARE @schemas TABLE (name SYSNAME);
INSERT INTO @schemas VALUES (N'src'), (N'stg'), (N'dim'), (N'fact'), (N'etl'), (N'audit'), (N'rpt'), (N'test');

DECLARE @name SYSNAME, @sql NVARCHAR(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @schemas;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = @name)
    BEGIN
        SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@name) + N' AUTHORIZATION dbo;';
        EXEC sys.sp_executesql @sql;
    END
    FETCH NEXT FROM c INTO @name;
END
CLOSE c; DEALLOCATE c;
GO

/* ---------- etl.Numbers : 1..1,048,576 tally table -------------------------
   Used by the data generator, the date dimension and the snapshot builder.
   Set-based generation (no loops): 2^20 rows from cross-joined constants.
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'etl.Numbers', N'U') IS NULL
BEGIN
    CREATE TABLE etl.Numbers (n INT NOT NULL CONSTRAINT PK_etl_Numbers PRIMARY KEY CLUSTERED);

    WITH L0 AS (SELECT 1 AS c FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS v(c)), -- 16
         L1 AS (SELECT 1 AS c FROM L0 a CROSS JOIN L0 b),          -- 256
         L2 AS (SELECT 1 AS c FROM L1 a CROSS JOIN L1 b),          -- 65,536
         L3 AS (SELECT 1 AS c FROM L2 a CROSS JOIN L0 b)           -- 1,048,576
    INSERT INTO etl.Numbers (n)
    SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM L3;
END
GO

/* ---------- etl.fn_Rnd : deterministic pseudo-random in [0,1) --------------
   Inline table-valued function (expanded by the optimizer, so it is cheap even
   across a million rows).  Same (@Salt, @n) always gives the same value, which
   makes the whole synthetic dataset reproducible without RAND() or NEWID().
   Usage:  CROSS APPLY etl.fn_Rnd('segment', n) AS r   ...   r.v
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION etl.fn_Rnd (@Salt VARCHAR(30), @n BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(ABS(CHECKSUM(HASHBYTES('MD5', CONCAT(@Salt, ':', @n))) % 1000000) AS DECIMAL(9,6)) / 1000000.0 AS v   -- % before ABS: no overflow on -2^31
);
GO

/* ---------- etl.fn_PickWeighted : map a [0,1) value onto weighted buckets ---
   @Weights = 'A:0.7|B:0.2|C:0.1'   → returns the label whose cumulative weight
   range contains @r.  Keeps the generator readable.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION etl.fn_PickWeighted (@Weights VARCHAR(400), @r DECIMAL(9,6))
RETURNS TABLE
AS
RETURN
(
    WITH parts AS
    (
        SELECT LTRIM(RTRIM(LEFT(value, CHARINDEX(':', value) - 1)))                  AS label,
               CAST(SUBSTRING(value, CHARINDEX(':', value) + 1, 20) AS DECIMAL(9,6)) AS w,
               ordinal = CHARINDEX('|' + value + '|', '|' + @Weights + '|')   -- position in the list: STRING_SPLIT has no guaranteed order
        FROM STRING_SPLIT(@Weights, '|')
    ),
    cum AS
    (
        SELECT label, w,
               SUM(w) OVER (ORDER BY ordinal ROWS UNBOUNDED PRECEDING) - w AS lo,
               SUM(w) OVER (ORDER BY ordinal ROWS UNBOUNDED PRECEDING)     AS hi
        FROM parts
    )
    SELECT TOP (1) label
    FROM cum
    WHERE @r >= lo AND (@r < hi OR hi >= 0.999999)
    ORDER BY lo
);
GO

/* ---------- etl.LoadLog + etl.Watermark : the load framework ---------------- */
IF OBJECT_ID(N'etl.LoadSeq', N'SO') IS NULL
    CREATE SEQUENCE etl.LoadSeq AS INT START WITH 1 INCREMENT BY 1;
GO

IF OBJECT_ID(N'etl.LoadLog', N'U') IS NULL
CREATE TABLE etl.LoadLog
(
    LogID          INT IDENTITY(1,1)  NOT NULL CONSTRAINT PK_etl_LoadLog PRIMARY KEY CLUSTERED,
    LoadID         INT                NOT NULL,
    StepName       SYSNAME            NOT NULL,
    StartedAt      DATETIME2(3)       NOT NULL CONSTRAINT DF_etl_LoadLog_StartedAt DEFAULT SYSUTCDATETIME(),
    EndedAt        DATETIME2(3)       NULL,
    RowsInserted   INT                NULL,
    RowsUpdated    INT                NULL,
    RowsRejected   INT                NULL,
    Status         VARCHAR(10)        NOT NULL CONSTRAINT DF_etl_LoadLog_Status DEFAULT 'Running',
    ErrorMessage   NVARCHAR(2000)     NULL,
    CONSTRAINT CK_etl_LoadLog_Status CHECK (Status IN ('Running','Succeeded','Failed','Skipped'))
);
GO

IF OBJECT_ID(N'etl.Watermark', N'U') IS NULL
CREATE TABLE etl.Watermark
(
    TableName       SYSNAME       NOT NULL CONSTRAINT PK_etl_Watermark PRIMARY KEY CLUSTERED,
    LastLoadedValue DATETIME2(3)  NOT NULL,
    LastLoadID      INT           NULL,
    UpdatedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_etl_Watermark_UpdatedAt DEFAULT SYSUTCDATETIME()
);
GO

/* ---------- etl.usp_LogStep : one-liner logging used by every procedure ----- */
CREATE OR ALTER PROCEDURE etl.usp_LogStep
    @LoadID        INT,
    @StepName      SYSNAME,
    @Status        VARCHAR(10),
    @RowsInserted  INT            = NULL,
    @RowsUpdated   INT            = NULL,
    @RowsRejected  INT            = NULL,
    @ErrorMessage  NVARCHAR(2000) = NULL,
    @LogID         INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Status = 'Running'
    BEGIN
        INSERT INTO etl.LoadLog (LoadID, StepName, Status) VALUES (@LoadID, @StepName, 'Running');
        SET @LogID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE etl.LoadLog
           SET EndedAt = SYSUTCDATETIME(), Status = @Status,
               RowsInserted = COALESCE(@RowsInserted, RowsInserted),
               RowsUpdated  = COALESCE(@RowsUpdated,  RowsUpdated),
               RowsRejected = COALESCE(@RowsRejected, RowsRejected),
               ErrorMessage = @ErrorMessage
         WHERE LogID = @LogID;
    END
END
GO

PRINT '00_create_database.sql completed: BankDW, 8 schemas, etl.Numbers, etl.fn_Rnd, etl.fn_PickWeighted, load framework.';
GO
