# Publishing checklist (delete this file once done)

1. **Run it.** Open `sql/run_all.sql` in SSMS (SQLCMD mode) and press F5 — or push and let the GitHub Actions
   workflow (`.github/workflows/ci.yml`) build it on a SQL Server 2022 container.
2. **Fill the numbers.** Replace the approximate volumes in `README.md` ("Approximate volumes after the
   initial load") and the `[brackets]` in `linkedin/posts.md` with the real output of
   `SELECT * FROM rpt.vw_LoadRuns`, `SELECT * FROM test.Results`, and query 1 in `06_analytics_queries.sql`.
3. **Screenshots.** Save SSMS screenshots of the test summary, `rpt.vw_DataQualityLatest` and the RFM matrix
   into `docs/img/` and reference them from the README ("Results" section).
4. **GitHub.** Create repo `bank-customer360-tsql` (public), description:
   *End-to-end bank data warehouse in pure T-SQL: synthetic core-banking data, Kimball star schema, SCD2,
   incremental idempotent loads, data-quality gate, Customer 360 with RFM & churn, 26 T-SQL tests.*
   Topics: `t-sql` `sql-server` `data-warehouse` `kimball` `star-schema` `scd2` `etl` `data-engineering`
   `data-quality` `columnstore` `azure-sql` `banking` `customer-360` `churn` `power-bi`.
   Pin it, and add a row to the Featured Projects table in your profile README.
5. **LinkedIn.** Featured link + Projects entry (see the texts in the conversation), then post 1 with
   `docs/img/architecture.png`.
