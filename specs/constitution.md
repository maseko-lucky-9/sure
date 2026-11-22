# Constitution

This fork adds South African personal-finance features to Sure while staying mergeable with
upstream (`we-promise/sure`). [AGENTS.md](../AGENTS.md) is the authority on code conventions;
this file adds only what is specific to the fork.

1. **Mergeable first.** Prefer new files over edits to upstream files. Every edit to an
   upstream file is listed in the pull request body.
2. **Preview-gated.** New screens sit behind `require_preview_features!`.
3. **Evidence before code.** Each change starts from a written hypothesis, an independent
   attempt to refute it, and a test that fails on `main` for the predicted reason.
4. **One spec per phase.** `specs/NNN-<slug>/` holds `spec.md` (what and why), `plan.md` (how)
   and `tasks.md` (checklist, ticked in the same pull request as the code).
5. **Verified locally.** GitHub Actions is off on this fork. A pull request merges only with
   the full Rails suite, lint and Brakeman green in the Docker test stack.
