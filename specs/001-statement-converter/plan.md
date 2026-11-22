# Phase 1: plan

`tools/sa-statement-converter/convert.ts`, run directly by Node 22.18+ (type stripping), with
`node --test` tests beside it. No change to application code.

- Output columns `date,amount,name,notes`, pushed as a `TransactionImport` with
  `signage_convention: inflows_positive` and an explicit `account_id`.
- A fee gets its own name because Sure's row matching includes the name.
- No file-hash ledger: Sure's row matching already makes a repeat import a no-op.
- `.xlsx` is read with `node:zlib`: first worksheet, shared and inline strings.
- Amounts are held as integer cents. Anything that is not certainly a decimal-point amount is
  refused, because a decimal comma cannot be told apart from a thousands separator.
- The push runs Sure's preflight first and creates the import only if it reads every row.
