# Phase 2: plan

One pull request per feature, each preview-gated.

1. **Debt planner**
   - `DebtPayoffPlan` (PORO): monthly interest, then minimums, then a pool of the extra amount
     plus freed minimums, applied in strategy order. 600-month cap; `NotConverging` when a
     debt can never clear.
   - `DebtPayoffPlan.debts_for` reads `Current.user.accessible_accounts` loans and cards. A loan's
     minimum is its contractual payment (excludes insurance); variable-rate loans have none and
     are left out, as are cards with a negative APR.
   - `DebtPlansController#show`, a card on the Plan hub.
2. **Spend forecast**
   - Extract `SpendingAnomalyGenerator#project` and its bill logic into
     `IncomeStatement::SpendingForecast`; the generator calls it.
   - Sum it for a month-end total with a range from the spread of daily spending
     (`IncomeStatement#daily_expense_series`).
   - Show it in the existing "spending vs normal" Reports section and its `as_json`.
3. **Savings opportunity insight**
   - Categories whose `SpendingComparison` row is above normal; the suggested saving is the
     amount above normal.
