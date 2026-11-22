# Phase 3: tasks

## Currency scale
- [x] Refuter: no scale mechanism exists; three more thresholds found
- [x] `Money::Scale`, eight use sites, boundary test per site, no-op regression tests
- [x] Independent review: transactions and goal outflows are judged in their own currency
- [x] Mutation checks: multiplier 1, decimal multiplier, family or goal scale on a mixed-currency row

## Tax-free savings caps
- [x] Refuter: no South African subtype, no cap tracking
- [x] Limits confirmed against SARS
- [x] Subtype, contribution PORO, account alert, tests

## 50/30/20
- [x] Refuter: no classification exists
- [x] Bucket per category, preview section, tests
- [x] Independent review: refunds netted, one-time exclusion stated, group restored on import
