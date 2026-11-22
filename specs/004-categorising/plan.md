# Phase 4: plan

One pull request per feature.

1. **Merchant rules**
   - `tools/sa-merchant-rules/rules.csv` in the format Sure's rule import reads, built from the
     Analyzer's keyword list and extended with common merchants: 18 rules, one or two per Sure default
     category (Utilities, Food & Drink and Fees are each split in two for the 200-character pattern
     limit). Each rule has a whole-word `transaction_name` regex condition, a "category is empty"
     condition so nothing already categorised is overwritten, and one set-category action. Income also
     has `transaction_type = income`, so only money coming in matches.
   - The file order is the run order and the first rule to set a category wins: Income first (so an
     employer named like a merchant still pays Income), Healthcare and Savings & Investments above
     Insurance, Food & Drink above Transportation. Loose keywords were narrowed or dropped for
     precision; the README lists them. A README gives the two steps: create the default categories,
     then import the file.
   - The file has no `group` column, so a re-import keeps the group a user chose.
   - `test/models/sa_merchant_rules_test.rb` imports the file into a family with the default
     categories, runs the rules the way a sync does, and checks sample statement lines, known
     misfires, rule order, keyword overlap between rules, categories that must not be overwritten
     (including old transactions and Apply All), and what a second import does.
   - `tools/sa-statement-converter/package.json` silences a Node module-type warning for the existing
     converter.
   - No upstream file is edited.
2. **Suggestions in the walkthrough**
   - `Transactions::CategorizesController#show` asks `Family::BayesCategorizer` for the best guess
     for the group on screen when it has enough training data.
   - The view shows "Suggested: Groceries (62%)" with a "Use Groceries" button that submits the walkthrough
     form like a category pill, so the rule checkbox state travels with it. Preview only.
   - `Transaction::CategorySuggestion` scores up to 20 of the group's transactions and offers the category with the
     highest mean probability, only when that mean is at least 0.30 (below it a guess among many categories is noise).
