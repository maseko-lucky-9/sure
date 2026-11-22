# South African statement converter

Sure's transaction import reads one signed amount column. South African bank exports use
separate **Money In**, **Money Out** and **Fee** columns, so a stock import leaves every
money-out row and every fee blank. This script converts such a file (CSV or `.xlsx`) and can
push the result to Sure.

It needs Node 22.18 or later and has no dependencies.

```sh
# Print the converted CSV
node convert.ts statement.csv

# Convert and import into an account
SURE_API_KEY=... node convert.ts statement.xlsx --account-id <account id> [--base-url http://localhost:3000] [--no-publish]
```

The API key needs read-write scope (Settings → API key). The account id is in the account's URL.

## What it does

- Money In becomes a positive amount, Money Out a negative one, whether or not the bank signs it.
- A fee becomes its own transaction named `<description> Fee`, or just the description on a fee-only row.
- A row with both Money In and Money Out becomes two transactions, with a warning.
- Rows with an unreadable date, no description, or no amount are skipped, with a warning naming the line.
- Dates are read day-first and written as `yyyy-mm-dd`. The posting date is used when the file has both a posting and a transaction date. The original description goes into notes.
- Amounts must use a decimal point (`1,234.56` or `1 234.56`). A row with any amount it cannot read for certain, such as `12,50` or `50.00 Dr`, is skipped whole with a warning; so is a row dated in the future.
- The header row may sit below account details, may be semicolon-separated, and may carry units such as `Money In (R)`.
- Categories are not sent: the imports API does not apply category columns.

Importing the same file twice is safe. Sure matches rows on date, amount and name, so the second import updates the existing transactions.

Before creating anything the script asks Sure for a dry run and stops unless Sure reads exactly the rows that were sent.

Descriptions are passed through unchanged, so a name starting with `=`, `+`, `-` or `@` stays that way. Do not open the converted CSV in a spreadsheet you do not trust it in.

## Tests

```sh
node --test convert.test.ts
```
