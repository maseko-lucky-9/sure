# Phase 5: plan

1. **Converter push fix** (`tools/sa-statement-converter/`): read `data.stats.rows_count` and
   `data.valid` from the preflight reply; the unit test uses the reply shape Sure's own API test
   pins, and a contract test in Sure's suite sends the converter's request and fixture output
   through the real import API.
2. **Money Out and Fee columns**
   - Optional `outflow_col_label` and `fee_col_label` in `imports.column_mappings`, chosen on the
     transaction import's configure step.
   - `TransactionImport#generate_rows_from_csv` builds rows from Money In minus Money Out, and a
     separate row for each fee, when a Money Out column is chosen; otherwise it behaves as before.
   - Acceptance cases are the Analyzer's fixtures (`test_money_in_out_fee.csv`,
     `sample_transactions_Format2Parser.csv`).
3. **Account page import link**: the menu item posts to create an import for that account.
