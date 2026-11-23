# Phase 7: close-out review

Written 2026-11-23. The goal was to bring the features where the Personal Finance Analyzer was
ahead into this fork of Sure, improved where a straight copy would have carried a defect.

## What was delivered

| Phase | Pull requests | Result |
| ----- | ------------- | ------ |
| 0 Security baseline | #4, #6 | Authorization gaps closed (family name and currency, import sharing, assistant account access, invite email); five gems updated |
| 1 Statement converter | #7, #16 | `tools/sa-statement-converter`: Money In, Money Out and Fee files to a signed CSV, with an optional push to the import API |
| 2 Advice | #8, #9, #10 | Debt payoff planner, month-end spending forecast, savings-opportunity insight |
| 3 South African tuning | #11, #12, #13 | Rand-scaled thresholds, tax-free savings allowance alert, needs/wants/savings report section |
| 4 Categorising | #14, #15 | South African merchant rules file, category suggestion in the categorise walkthrough |
| 5 Native import | #17 | Money out and Fee columns on the transaction import; account import links start an import for that account |
| 6 Offline PDF reader | none | Deferred. No real statement to verify a layout against |
| 7 Close-out | upstream sync | Merged upstream `main`; one conflict, the schema version line |

## What the hypothesis gate changed

Each phase began with a hypothesis, an independent attempt to refute it, and a test on `main` or
the live app. The refutations that changed the build:

- **Phase 3.** Thresholds on raw entry amounts needed a per-row currency rule, not one family-wide
  multiplier.
- **Phase 4.** Sure already runs its own classifier after every import. The gap was the cold start,
  so the build became a rules file and a suggestion for guesses below the auto-apply threshold,
  not a separate review queue.
- **Phase 5.** A new import type, Excel upload in the app and filename-based account matching were
  dropped. Two optional columns on the existing import covered the need.
- **Phase 6.** No bank layout can be verified without a real statement, and the live app has no AI
  provider and no PDF imports for a balance check to act on. Nothing was built.

## Defects found in this work, and how

- **Converter push (Phase 1).** It read the row count from the wrong field of the preflight reply,
  so every push stopped before importing. The unit test mocked the wrong reply shape. Found by
  the Phase 5 refuter; fixed in #16, with a contract test that sends the converter's request
  through the real import API.
- **Money out and Fee import (Phase 5).** Independent review found lines that could be dropped or
  misread without a signal (negative money in, parentheses, another format's notation, a column
  missing from the file). A second verification found that the new validation raised on
  unrelated saves after a file was replaced. All fixed before merge.

## Not done

| Item | Why | What unblocks it |
| ---- | --- | ---------------- |
| Converter push against a running Sure | Needs a read-write API key from the owner | A key in `SURE_API_KEY` |
| Offline bank PDF reader | No real statement to verify against | Two or three statements per bank with matching CSV exports |
| H4: confirmation before the assistant deletes | Needs a confirmation step in the chat UI | A decision to build it |
| H6: enforced content security policy | Needs an audit of inline scripts and provider widgets | A decision to do the audit |
| Dedicated review screen with reject and undo | The walkthrough suggestion covered the need found | A request for it |
| Excel upload inside Sure | The converter reads Excel; no spreadsheet gem in the app | A request for it |
| Persona simulator | Not selected | |

## Known limits a user can meet

- A statement line whose money cells are all blank or zero produces no row.
- `1 234.56` (space grouping with a decimal point) matches none of Sure's four number formats and
  is flagged invalid on the clean step.
- A fee refund in a Fee column is read as a charge.
- Without a money out column, a blank amount still falls back to a column named Balance, as
  upstream Sure does.
- The category suggestion appears only for guesses between 30% and 70%; Sure applies anything
  higher on its own.
- The merchant rules need the default categories and a one-off rule import.

## Fork drift

Upstream files edited by the fork are listed in each pull request. Upstream offers (currency
scale, Money out and Fee columns, debt planner) are not made without the owner's go-ahead.
