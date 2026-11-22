# Phase 5: native statement import

## Why

South African bank exports split amounts across Money In, Money Out and Fee columns. Sure's CSV
import maps one amount column. A converter outside the app (Phase 1) covers this today; this phase
brings the common case into Sure itself.

## Hypotheses, refutation and tests

An independent reviewer was asked to show each gap does not exist.

| Feature | Verdict | What Sure already has | What is missing |
| ------- | ------- | --------------------- | --------------- |
| Money In / Money Out / Fee columns | Confirmed, re-shaped | One amount column with a sign option; a YNAB type with fixed `Inflow` / `Outflow` headers and no duplicate check | Mapping a second amount column and a fee column |
| Excel upload | Partial | `rubyzip`; statement storage accepts `.xlsx` but only stores it | Reading a sheet into rows |
| Account auto-pick | Refuted as planned | The account select pre-fills once the import knows its account; an Account column maps by name | The account page's import link does not carry the account |

Findings that changed the plan:

- With one amount column mapped to Money In, a money-out row has a blank amount and Sure falls
  back to the Balance column, so the running balance is imported as the amount.
- The converter's push step read the wrong field of Sure's preflight reply and so never pushed.
  It failed safe: nothing was imported.

## Scope after refutation

1. **Converter push fix.** Read the row count where Sure's preflight reply carries it.
2. **Money Out and Fee columns as options on the existing transaction import**, not a new import
   type: the existing type keeps its duplicate check, date and number formats and account choice.
   Each fee becomes its own row named "<description> Fee", as the converter does.
3. **Account page import link** carries the account into the new import.

Not built, and why:

- **Excel upload in the app.** It needs a parser for untrusted zip and XML on four upload paths,
  with size and entity limits and date-style handling. Every bank portal and spreadsheet app can
  save CSV, and the converter already reads `.xlsx`.
- **Account matching from the file name.** The upload form's blank account means "multi-account
  import", so a guessed account would override a deliberate choice.
- **API parameters for the new columns.** The converter already covers scripted imports.
