# Suggested report layout (5 pages)

Theme: navy `#1F2A44` titles, deep blue `#1F4E79` primary, teal `#117865` positive, red `#CC2927`
alerts, light grey `#F2F4F7` canvas. Every page: title top-left, as-of date (`MAX(Customer360[SnapshotDate])`)
top-right, slicers for Segment, Governorate and Fiscal Year in a left rail.

## 1 — Executive overview
* KPI cards: Customers, Churn Rate %, High Risk Customers, Deposits Under Management, Deposits at Risk, Digital Share %.
* Line: Active Customers by month with MoM % as a tooltip; 3-month moving average as a second line.
* Stacked column: Net Flow by month split into Credits / Debits.
* Bar: Churn Rate % by Segment (sorted), conditional colour by value.

## 2 — Customer 360 & churn
* Matrix (heat-map): RecencyScore × FrequencyScore, value = Customers, colour saturation = Deposits Under Management.
* Bar: Customers by RFMSegment.
* Table: High-risk customers — FullName, Segment, ProductsHeld, DaysSinceLastTxn, OpenComplaints, TotalDepositBalance, ChurnRiskReasons — sorted by TotalDepositBalance desc. This is the call list for retention.
* Scatter: TenureMonths vs MonthlyTxnAvg, size = TotalDepositBalance, colour = ChurnRiskBand.

## 3 — Products & channels
* Bar: product penetration (share of customers holding each product) from `rpt.vw_ProductPenetration`.
* 100 % stacked column: channel mix by month (Mobile, Internet, ATM, POS, Branch, CallCenter).
* Matrix: cross-sell affinity — product pairs held together (query 11 as a view or an imported result).
* Bar: Card Spend by MerchantCategory, drill from Segment.

## 4 — Branch performance
* Map (Governorate) sized by Customers, coloured by Churn Rate %.
* Table from `rpt.vw_BranchPerformance`: Branch, Region, Accounts, Customers, TxnCount, FeeIncome, BranchChannelTxnPct, DormantAccounts — add a RANKX measure on FeeIncome.
* Decomposition tree: Churned Customers by Region → Governorate → Branch → Segment.

## 5 — Data quality & operations
* Card: DQ Status (PASS / WARN / FAIL) with conditional colour.
* Table: latest checks — CheckName, Severity, Status, Observed, Expected, Details.
* Table: `rpt.vw_LoadRuns` — steps of the last load with duration and rows.
* Bar: rejected rows by Reason (from `stg.Rejected`, latest LoadID).

Drill-through page: **Customer history** — `rpt.vw_CustomerHistory` (SCD2 versions with ValidFrom / ValidTo)
plus the customer's monthly balance line from the snapshot.
