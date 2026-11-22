# Phase 0: plan

Two pull requests, each verified by the full suite in the Docker test stack.

1. **Authorization** (H1, H2, H3, H7)
   - `UsersController`: a different family name or currency requires an admin.
   - `Import#visible_to?` is the single read check (statement viewable, target accounts
     accessible). `ImportGuestGuardable#require_import_account_access!` applies it to every
     import wizard step and to the import page actions; the imports API applies it too.
   - `Import.for_accounts_accessible_by` filters the web and API import lists.
   - `Assistant::Function::CreateGoal` uses `user.accessible_accounts`;
     `ImportBankStatement` uses `family.accounts.writable_by(user)` and `visible_to?`.
   - The invite email drops `html_safe`.
2. **Dependencies** (H10): lockfile only, Gemfile constraints unchanged.

H4 and H6 are deferred and need a product decision. H5, H8 and H9 need no change.

## Known limits

- Timezone, date format, country, locale and month start day stay editable by any member.
- The import list filter looks only at the import's own account; an import that maps to a
  hidden account by column can appear in the list (type, status, row count) and returns 404
  when opened.
