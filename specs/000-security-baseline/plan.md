# Phase 0: plan

Two pull requests, each verified by the full suite in the Docker test stack.

1. **Authorization** (H1, H2, H3, H7)
   - `UsersController#user_params` permits family attributes for admins only.
   - `ImportGuestGuardable#require_import_account_access!` runs before every import wizard step.
   - `Assistant::Function::CreateGoal` uses `user.accessible_accounts`;
     `ImportBankStatement` uses `family.accounts.writable_by(user)`.
   - The invite email drops `html_safe`.
2. **Dependencies** (H10)

H4 and H6 are deferred and need a product decision. H5, H8 and H9 need no change.
