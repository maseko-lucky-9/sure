# Phase 5: plan

1. **Converter push fix** (`tools/sa-statement-converter/`): read `data.stats.rows_count` and
   `data.valid` from the preflight reply; the unit test uses the reply shape Sure's own API test
   pins, and a contract test in Sure's suite sends the converter's request and fixture output
   through the real import API.
2. **Money Out and Fee columns**
   - Optional `outflow_col_label` and `fee_col_label` in `imports.column_mappings`, chosen on the
     transaction import's configure step. The existing amount column is read as Money In when a
     Money Out column is chosen.
   - `TransactionImport#generate_rows_from_csv` builds rows from Money In, Money Out and Fee when a
     Money Out column is chosen, reading only the mapped columns (no Balance fallback); otherwise it
     behaves as before. A line with both money in and money out becomes two rows, each non-zero fee
     its own row named "<description> Fee" (always money out), and rows are renumbered so
     `source_row_number` stays unique.
   - Signed reading: a negative Money In is an outflow of that size (money in minus |money out|), and
     its fee is still imported. Money Out and Fee are outflows by absolute value.
   - Strict number check: each cell must be an optional minus, then digits grouped as the import's
     `number_format` says (derived from `Import::NUMBER_FORMATS`), after trimming space and a leading
     currency (R, ZAR, $, euro, pound). Anything else (parentheses, Unicode minus, trailing minus,
     CR/DR, another format's notation, letters) makes the line one row with a blank amount, which
     the clean step flags and which blocks publishing. Nothing is guessed or dropped silently.
   - Three refusals, as validations (the configure step shows them) and as a `RecordInvalid` from
     `generate_rows_from_csv` before any row is touched: a fee column without a money out column,
     one column in two roles, and a chosen column the uploaded file does not have.
   - Choosing a Money Out column forces `signed_amount` and `inflows_positive` (a before-validation
     callback, the single source of truth). The two selects stay editable with an explanation.
     Import templates copy the two labels when the new file has all the columns.
   - The three checks run only in a save that changes the columns, the amount column, the file, the
     separator or `rows_to_skip` (or re-submits the money columns), so an unrelated update on a stale
     import cannot raise. A save that brings a new file or header row without choosing the money
     columns drops them when any is no longer among the headers (`before_save` and
     `before_validation`, so uploads, which skip validation, and the `rows_to_skip` refresh both
     reach it). A template's money columns and its forced sign convention are carried only together.
   - Acceptance cases are the converter's fixture (`money_in_out_fee.csv` and its converted output)
     and cases ported from the Analyzer's `sample_transactions_Format2Parser.csv`.
3. **Account page import link**: the menu items are POST buttons to `imports#create` with the
   account id, as the import option buttons are, so the new import is created for that account.
