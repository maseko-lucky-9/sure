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
   - A South African tax-free subtype (`tfsa_za`) for investment accounts. A tax-free account held at a bank
     should be added as an investment account for now; a depository subtype is not built.
   - A PORO that sums a person's contributions per tax year (1 March to end of February) across
     their tax-free accounts and compares them with that year's limit and the lifetime limit.
   - An alert on the account page; no new insight type.
   - Built: `Account::TaxFreeAllowance` and the alert. It counts deposits, not returns, and never gives room back
     for a withdrawal. A confirmed transfer between the owner's own tax-free accounts is not counted.
   - Blind spots: money put in before the account was tracked in Sure is missing, so the lifetime figure is a lower
     bound; interest imported as a plain transaction counts as a deposit; a transfer from another provider's
     tax-free account counts as a deposit. The alert hides if any family member who can open the account cannot
     open all of the owner's tax-free accounts.
   - Also: accounts in another currency are skipped, and every tax-free account under one login
     is taken to be one person's.
3. **50/30/20**
   - A needs / wants / savings bucket per category, defaulted from Sure's default category keys
     and editable, with unassigned categories shown.
   - A preview section comparing each bucket's share of income with 50/30/20.
   - Built: a preview section in Reports (not a budget tab), `IncomeStatement::NeedsWantsSavings`, over the
     refund-netted category groups Sure's flow charts use, so a refund is never income. Savings is spending in savings categories plus income left unspent, so the
     groups add up to income. A category's group is editable on its form; unassigned spending is listed, not guessed.
   - Left out, as in the income statement: transfers between own accounts, card payments and
     transactions marked one-time. The group is restored by a family import.
