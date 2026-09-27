# LinkedIn posts for this project

Three posts, one per week. Replace every `[bracket]` with your real numbers **after** you have run the
project (`SELECT * FROM rpt.vw_LoadRuns`, `test.Results`, `rpt.Customer360`). Attach
`docs/img/architecture.png` to post 1 and screenshots of SSMS results to posts 2 and 3.
Keep the first line short — it is the only thing people see before "…see more".

---

## Post 1 — the launch (attach `docs/img/architecture.png`)

I built a complete bank data warehouse in pure T-SQL. No Python, no ETL tool — just SQL Server.

Why? Because banks run on SQL Server, and the patterns their data teams use every day are rarely shown
end to end in one place. So I built the whole thing:

▪ Synthetic core-banking data generated *in SQL* — 20 000 customers, ~1 M transactions, with duplicates,
  orphans and future dates planted on purpose
▪ Staging & cleansing with rejects-with-reasons
▪ Kimball star schema with an SCD Type 2 customer dimension (MERGE + OUTPUT)
▪ Incremental, idempotent fact loads (watermark + look-back, point-in-time surrogate keys)
▪ A data-quality gate: 13 checks, PASS / WARN / FAIL, the load stops on FAIL
▪ A Customer 360 table with RFM scores and a churn flag
▪ 12 analytics queries (gaps & islands, cohorts, PIVOT, PERCENTILE_CONT …)
▪ 26 T-SQL test assertions — including "run it twice, nothing changes"

It runs from one script in SSMS in about [X] minutes.

Repo: [GitHub link]

The most interesting bug I fixed along the way is in the comments 👇

#SQLServer #TSQL #DataEngineering #DataWarehouse #Kimball #Banking #PowerBI

**First comment:** The SCD2 load. My first version was one MERGE that expired the old row AND inserted
the new one via INSERT … SELECT FROM (MERGE … OUTPUT). SQL Server refuses that when the target has a CHECK
constraint. The fix: capture $action and the source columns with OUTPUT … INTO a table variable, then
insert the new versions in a second statement — same transaction, no nesting. Details in the README.

---

## Post 2 — the incremental load (attach an SSMS screenshot of `rpt.vw_LoadRuns` or the test results)

"Just reload everything" stops being an option at a bank.

The second thing I made sure this warehouse does well is the daily delta:

1. Stage only rows with CreatedAt > watermark − 1 hour. The look-back catches late arrivals.
2. Anti-join on the business key so a re-sent file inserts nothing twice.
3. Look up the customer's SCD2 version *valid on the transaction date* — not today's version — so
   "churn by segment" is answered with the segment the customer was in at the time.
4. Advance the watermark only after the fact load commits.
5. Run the quality gate; on FAIL the load throws and the log tells you which check.

Then I wrote a test that runs the whole incremental load a second time and asserts:
[0] new fact rows, [0] new customer versions. That test is the one I care about most.

Day-2 simulation script and the test harness are in the repo: [GitHub link]

#SQLServer #TSQL #DataEngineering #ETL #SCD2

---

## Post 3 — what the data said (attach a screenshot of the RFM matrix or the risk-band bar chart)

The warehouse is the means. The question was: who is about to leave the bank?

From the Customer 360 table (synthetic data, [N] customers):

▪ Churn rate overall: [X] % — highest in [segment] at [Y] %
▪ [Z] % of high-risk customers hold a single product
▪ Customers with an open complaint are [K]× more likely to be flagged high-risk
▪ Digital-first customers (>[P] % of transactions on mobile/internet) churn at [Q] % vs [R] % for branch-first

All of it comes from set-based SQL: NTILE for the RFM quintiles, window frames for balances and
dormancy streaks, STRING_AGG for the human-readable risk reasons ("inactive 45 days; 1 open
complaint(s); single product") that a retention team can act on.

Next: the Power BI report on top — the measures and page layout are already in the repo.

[GitHub link]

#SQL #Analytics #CustomerChurn #Banking #PowerBI #DataEngineering
