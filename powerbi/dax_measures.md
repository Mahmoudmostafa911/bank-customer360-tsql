# Power BI on top of BankDW

Connect Power BI Desktop to `BankDW` (Import or DirectQuery) and load the `rpt` views plus the
dimensions. The star is already conformed, so the model is a plain import of:

| Table in the model | Source | Role |
|---|---|---|
| `Transactions` | `rpt.vw_TransactionDetail` or `fact.Transaction` | fact |
| `Snapshot` | `fact.AccountMonthSnapshot` | periodic snapshot fact |
| `Customer360` | `rpt.Customer360` | one row per current customer |
| `Customer` | `dim.Customer` (filter `IsCurrent = 1` for the report, keep history for the SCD page) | dimension |
| `Account`, `Product`, `Branch`, `Channel`, `TransactionType` | `dim.*` | dimensions |
| `Date` | `dim.Date` — mark as date table on `FullDate` | dimension |
| `DataQuality`, `LoadRuns` | `rpt.vw_DataQualityLatest`, `rpt.vw_LoadRuns` | monitoring page |

Relationships: `Transactions[DateKey] → Date[DateKey]`, `Transactions[CustomerKey] → Customer[CustomerKey]`,
`Transactions[AccountKey] → Account[AccountKey]`, … (all many-to-one, single direction);
`Snapshot[MonthKey] → Date[MonthKey]` is many-to-many at month grain — prefer a small `Month` table
(`SELECT DISTINCT MonthKey, MonthStartDate, QuarterLabel, FiscalYear FROM dim.Date`) as the bridge.

## Measures

```dax
-- Activity ---------------------------------------------------------------
Transactions = COUNTROWS ( Transactions )

Active Customers =
    DISTINCTCOUNT ( Transactions[CustomerID] )

Active Customers PM =
    CALCULATE ( [Active Customers], DATEADD ( 'Date'[FullDate], -1, MONTH ) )

Active Customers MoM % =
    DIVIDE ( [Active Customers] - [Active Customers PM], [Active Customers PM] )

Digital Share % =
    DIVIDE (
        CALCULATE ( [Transactions], Channel[IsDigital] = TRUE () ),
        [Transactions]
    )

-- Money ------------------------------------------------------------------
Credits = CALCULATE ( SUM ( Transactions[Amount] ), Transactions[IsCredit] = TRUE () )
Debits  = CALCULATE ( -SUM ( Transactions[Amount] ), Transactions[IsCredit] = FALSE () )
Net Flow = [Credits] - [Debits]

Fee Income =
    CALCULATE ( -SUM ( Transactions[Amount] ), TransactionType[IsRevenueForBank] = TRUE () )

Card Spend =
    CALCULATE ( -SUM ( Transactions[Amount] ), TransactionType[TxnType] = "CardPurchase" )

-- Balances (periodic snapshot: take the last month in context, never sum months) ----
Closing Balance =
    VAR LastMonth = MAX ( Snapshot[MonthKey] )
    RETURN CALCULATE ( SUM ( Snapshot[ClosingBalance] ), Snapshot[MonthKey] = LastMonth )

Dormant Accounts =
    VAR LastMonth = MAX ( Snapshot[MonthKey] )
    RETURN CALCULATE ( COUNTROWS ( Snapshot ), Snapshot[MonthKey] = LastMonth, Snapshot[IsDormant3M] = TRUE (), Snapshot[IsOpen] = TRUE () )

-- Customer 360 -------------------------------------------------------------
Customers = COUNTROWS ( Customer360 )
Churned Customers = CALCULATE ( [Customers], Customer360[IsChurned] = TRUE () )
Churn Rate % = DIVIDE ( [Churned Customers], [Customers] )
High Risk Customers = CALCULATE ( [Customers], Customer360[ChurnRiskBand] = "High" )
Avg Products per Customer = AVERAGE ( Customer360[ProductsHeld] )
Single-Product Customers % = DIVIDE ( CALCULATE ( [Customers], Customer360[ProductsHeld] = 1 ), [Customers] )
Avg Days Since Last Txn = AVERAGE ( Customer360[DaysSinceLastTxn] )
Deposits Under Management = SUM ( Customer360[TotalDepositBalance] )
Deposits at Risk = CALCULATE ( [Deposits Under Management], Customer360[ChurnRiskBand] = "High" )

-- Complaints -----------------------------------------------------------------
Complaints = COUNTROWS ( Complaint )
Open Complaints = CALCULATE ( [Complaints], Complaint[Status] IN { "Open", "Escalated" } )
Median Resolution Days = MEDIAN ( Complaint[ResolutionDays] )
Complaints per 1k Customers = DIVIDE ( [Complaints], [Customers] ) * 1000

-- Data quality -----------------------------------------------------------------
DQ Failed Checks = CALCULATE ( COUNTROWS ( DataQuality ), DataQuality[Status] = "FAIL" )
DQ Status =
    IF ( [DQ Failed Checks] > 0, "FAIL", IF ( CALCULATE ( COUNTROWS ( DataQuality ), DataQuality[Status] = "WARN" ) > 0, "WARN", "PASS" ) )
Last Load Duration (s) = MAX ( LoadRuns[RunDurationSec] )
```

## Formatting conventions

* Currency measures: `#,0 "EGP"`; percentages: `0.0 %`; counts: `#,0`.
* Colour churn risk with a fixed palette: Low `#117865`, Medium `#F2A900`, High `#CC2927`.
* Use `Customer360[RFMSegment]` as the legend for the RFM matrix (Recency × Frequency heat-map).
