# Phase 2: advice

## Why

Three pieces of advice the Analyzer offers are missing or incomplete in Sure:

- a plan for paying off several debts at once (snowball or avalanche);
- a per-category "where to cut" recommendation;
- a forecast of this month's spending.

## Hypotheses, refutation and tests

An independent reviewer was asked to show each gap does not exist.

| Feature | Verdict | What Sure already has | What is missing |
| ------- | ------- | --------------------- | --------------- |
| Debt planner | Confirmed | Per-loan schedule and extra-payment simulator | Any cross-debt plan; no route or code mentions debt plans, snowball or avalanche |
| Where to cut | Partial | `SpendingAnomalyGenerator` flags categories on pace for 25%+ above normal; Reports "spending vs normal" ranks changes (both preview) | A suggested saving per category; no insight type or text mentions saving or cutting |
| Spend forecast | Partial | `SpendingAnomalyGenerator#project` projects each category's month-end spend, bill-aware (`spending_anomaly_generator.rb:96`) | A month-end total; nothing sums or shows it |

## Improvements over the Analyzer

- The debt planner rolls a cleared debt's full minimum into the next target; the Analyzer's own
  test pins the opposite. Debts come from real loan and card accounts, and anything that cannot be
  planned is listed with the reason.
- A savings suggestion is sized by how far a category runs above its own normal, not a flat 15%.
- The forecast reuses the anomaly insight's projection, so the two never disagree.
