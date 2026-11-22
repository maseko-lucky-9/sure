# South African merchant rules

`rules.csv` is a ready-made set of 18 rules for Sure's rule import. Each rule sets a category when a
transaction name contains a known South African merchant or statement phrase, such as Checkers, Eskom,
Vodacom or "Monthly Acc Fee". It gives a new family categorised transactions before the built-in
classifier has the 20 labelled transactions it needs.

## Use it

1. **Create Sure's default categories.** Open Settings → Categories and press **Use defaults
   (recommended)**. That button only shows while the family has no categories. If you already have
   some, add the missing names from the list below by hand.
2. **Import the file.** Open Settings → Imports → **New Import**, choose the **Raw Data** tab, then
   **Import rules**. On the upload page choose the **Upload CSV** tab, pick `rules.csv` and press
   **Upload CSV**. Press **Process Rules**, check the rows, then press **Publish import**.

The rules use these category names: Groceries, Food & Drink, Transportation, Shopping, Home
Improvement, Fees, Savings & Investments, Utilities, Healthcare, Insurance, Entertainment, Income,
Mortgage / Rent, Loan Payments, Taxes.

## What happens afterwards

- The rules run after every import and every sync. They have no start date, so they look at your whole
  history, not only new transactions.
- Every rule only acts on a transaction that has no category. A transaction that already has one is
  left as it is, whether you chose it, an imported file carried it, or a bank sync set it. Nothing
  existing is overwritten.
- That also holds for **Re-apply rule** and **Apply All** in Settings → Rules: they ignore the lock on
  a category you set by hand, but a transaction with a category still does not match, so they only fill
  transactions that have none. A transaction whose category you cleared is filled again.
- Because a category is never replaced, changing a keyword later does not correct transactions the
  old keyword already categorised. Fix those by hand.
- Rules run top to bottom and the first rule to set a category wins. The order in the file matters, so
  keep it if you move the rules:
  - Income is first, so money coming in from "Salary Shoprite Holdings" or "Satrix Dividend" is Income.
    Only Income is limited to money coming in. The same names as money going out get the merchant's
    category.
  - Healthcare and Savings & Investments are above Insurance, so "Discovery Health", "Momentum Health"
    and "Old Mutual Invest" are not Insurance.
  - Food & Drink is above Transportation, so "Uber Eats" is not a taxi ride.
  - Rules you already had run before these.
- The categories the rules set count as labels for the built-in classifier, so they help it start.

## Change a keyword

Open Settings → Rules, open the rule, and edit the text in its "matches regex" condition. It looks
like `\y(?:checkers|shoprite|spar)\y`: keep `\y` at both ends (it means a whole word, so "spar" does not
match "sparkle"), separate keywords with `|`, and use `\s+` for a space. Matching ignores case. Sure
rejects a pattern longer than 200 characters, which is why Utilities, Food & Drink and Fees are each
split into two rules. The first Food & Drink rule, Healthcare and Fees are close to the limit, so add new keywords
as a new rule below them.

To start from a date, choose an effective date in the same form.

## Importing twice

Rules are matched by name, so importing the file again updates the 18 rules instead of adding copies.
For each rule it:

- puts back the keywords and conditions from the file, discarding your edits;
- switches the rule on, even if you turned it off;
- clears an effective date you set;
- keeps the rule's position and the group you put it in.

If you rename a rule and import again, the file adds a new rule under the original name.

## Left out on purpose

These are not matched, because a missed line costs one click and a wrong category is silent:

- Transfers (`payshap`, `digital transf`, `eft` and similar). Sure treats a transfer as a kind of
  transaction, not a category.
- Generic words: `total` on its own ("TOTAL DUE" is not fuel; Total stations still match on
  `total fillpoint` and `totalenergies`), `rates` on its own (`rates and taxes` matches), `premium`,
  `refund`, `reversal`, `credit transfer`, `prepaid debit` and `gems`.
- Plain `woolworths` (it also covers clothing and Woolworths Financial Services; `woolworths food`
  and `woolies` match), plain `discovery` (Discovery Bank and cards are not insurance; only Discovery
  Insure, Life and Vitality match), plain `bolt` (Bolt Hardware; `bolt.eu` and `bolt ride` match) and
  `municipal` (`municipality` matches).

## Limits

- Categories are found by their English default names. A family using another language, or one that
  renamed or deleted a default category, must edit the category names in the file first. If a name is
  missing, the import creates a plain grey category with that name instead of failing.
- Whole-word matching misses a merchant name run into the next word, such as "CHECKERSSANDTON".
- A rule only sees the transaction name. Names that do not contain one of the keywords stay uncategorised.
- Some lines still get the wrong category rather than none:
  - An insurer's investment product, such as "MOMENTUM WEALTH" or "SANLAM RETIREMENT ANNUITY", is filed
    under Insurance.
  - Rent you receive from a tenant ("RENT PAYMENT" coming in) is filed under Mortgage / Rent.
  - A bank fee that names a shop, such as "CASH WITHDRAWAL FEE SHOPRITE", is filed under Groceries.
  - A grocer's other shops, such as "PNP LIQUORS" or "PICK N PAY CLOTHING", are filed under Groceries.
  Correct these by hand; a category you set is never changed by the rules.
