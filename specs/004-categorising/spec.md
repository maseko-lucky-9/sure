# Phase 4: categorising

## Why

A new family in Sure gets nothing categorised automatically: the built-in classifier waits for 20
hand-labelled transactions, and the AI categoriser needs an API key. When the classifier is not
confident it throws its guess away, so the user never sees it.

## Hypotheses, refutation and tests

An independent reviewer was asked to show each gap does not exist.

| Feature | Verdict | What Sure already has | What is missing |
| ------- | ------- | --------------------- | --------------- |
| South African merchant keywords | Partial | A rule engine with whole-word regex conditions, run after every sync and import; rule labels train the classifier | Any merchant list |
| Review queue | Partial | A categorise walkthrough; a classifier that can score any transaction on demand; a "always categorise X as Y" rule checkbox | Showing the guess and its confidence to the user |

Tests run on the live app (`main`):

- `Rule::SafeRegex.error_for('\y(?:spar|shoprite)\y')` returned `nil`: the rule engine accepts a
  whole-word pattern, so no new categoriser is needed.
- A search for "suggest" or "confidence" in the categorise walkthrough found nothing: it shows no
  guess today.

## Scope after refutation

1. **Merchant rules, not a new engine.** Rules with a whole-word pattern (18 rules for 15 categories), shipped
   as a file for Sure's existing rule import. Rules run after every import, and what they label
   trains the classifier, which also ends its cold start.
2. **Suggestions in the walkthrough, not a new table and screen.** The classifier's best guess and
   confidence are shown beside each group in the existing walkthrough, with the category
   pre-selected. Preview only.

Not built, and why:

- A `categorization_suggestions` table: guesses are computed when the page is opened, so a stored
  copy would only go stale.
- Remembered rejections: choosing a different category in the walkthrough already labels the
  transaction, trains the classifier and can create a rule.

## Improvements over the Analyzer

- Whole-word matching. The Analyzer matches substrings, so "spar" matches "Sparkle Cleaners",
  "rain" matches "Training fee" and "eft" matches "Car theft cover".
- A fixed rule order, so "Momentum Health" is health while other "Momentum" lines are insurance,
  and "Uber Eats" is food while other "Uber" lines are transport.
- The Analyzer's "Transfers" keywords are dropped: Sure models transfers as a transaction kind,
  not a category.
