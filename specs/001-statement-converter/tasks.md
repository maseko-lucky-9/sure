# Phase 1: tasks

- [x] Hypothesis test on `main` (`rows=10 valid=4`)
- [x] Converter: split columns, fee rows, day-first dates, warnings
- [x] `.xlsx` reader
- [x] Push only after Sure's dry run reads every row
- [x] Independent review: decimal commas, unreadable amounts, future dates, header detection, argument parsing
- [x] Unit tests (13), with mutation checks on the sign, the dry-run gate, unreadable amounts and future dates
- [x] Converted fixture through `TransactionImport`: `rows=12 valid=12`, 12 entries, 12 after re-import
- [ ] Push against a running Sure with a real API key (needs a key from the owner)
