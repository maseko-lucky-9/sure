# Phase 3: plan

One pull request per feature.

1. **Currency scale**
   - `Money::Scale` (`lib/money/scale.rb`): ISO code to an integer multiplier, default 1, `ZAR` 20. Static, not
     rate-based: nightly jobs run offline, and a drifting rate would change dedup keys.
   - Applied to eight thresholds: five insight generators, `Goal::WithdrawalDetector`, the weekly
     cleanup's missing-context detector and the subscription ceiling.
   - Integers throughout, so a multiplier of 1 leaves stored metadata and dedup keys identical.
   - Family-currency figures scale by the family's currency; raw transaction amounts scale by
     each transaction's own currency.
   - First nightly run for a rand family: old net-worth milestone cards expire, and a current
     low-balance warning is re-notified once because its bucket width changes.
2. **Tax-free savings caps**
   - A South African tax-free subtype for investment and depository accounts.
   - A PORO that sums a person's contributions per tax year (1 March to end of February) across
     their tax-free accounts and compares them with that year's limit and the lifetime limit.
   - An alert on the account page; no new insight type.
3. **50/30/20**
   - A needs / wants / savings bucket per category, defaulted from Sure's default category keys
     and editable, with unassigned categories shown.
   - A preview section comparing each bucket's share of income with 50/30/20.
