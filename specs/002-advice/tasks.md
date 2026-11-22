# Phase 2: tasks

## Debt planner
- [x] Hypothesis test on `main`
- [x] Model with golden cases (roll-over, clamp, amortisation count, avalanche vs snowball)
- [x] Page, Plan hub card, preview gate, member sees only shared debts
- [x] Independent review; negative card APR no longer fails the page
- [x] Mutation checks: roll-over, clamp, access scope

## Spend forecast
- [x] Refuter: projection exists per category, no total
- [x] Shared forecast class; the anomaly insight uses it (all 24 generator tests also pass on the pre-refactor generator)
- [x] Month-end total and range in the "spending vs normal" section and its JSON
- [x] Independent review: "normally" only with three months of history; range worded as "could land between"
- [x] Mutation checks: pace removed (16 tests red), insight no longer skipping uncategorized (1 red)

## Savings opportunity insight
- [x] Refuter: overspend flagged, no suggested saving
- [x] One insight per finished month: categories above normal two months running, the smaller overage claimed
- [x] Independent review: no single-month spikes, six months of history, three-day settle, medium priority only (no push)
- [x] Mutation checks: one month enough, no history minimum, no settle wait, larger overage, uncategorized named, unshared accounts read
