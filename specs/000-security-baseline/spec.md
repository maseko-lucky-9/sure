# Phase 0: security baseline

## Why

The feature phases build on the import wizard, the assistant and family settings. A security
review of the fork found gaps in those areas. They are closed first so later work does not
build on them.

## Findings and verdicts

Each finding was challenged by an independent reviewer asked to refute it.

| # | Finding | Verdict | Action |
| - | ------- | ------- | ------ |
| H1 | Non-admin members can change family name, currency, timezone and month start | Confirmed | Fix |
| H2 | Import wizard steps do not check access to the import's accounts | Partial: publish is guarded, viewing and editing rows is not | Fix |
| H3 | Assistant `create_goal` and `import_bank_statement` resolve accounts family-wide | Confirmed / partial | Fix |
| H4 | Assistant runs irreversible deletes without confirmation | Partial: by design | Deferred: needs a confirmation step in the chat UI; a tool parameter alone would not stop injected instructions |
| H5 | Production only warns on a placeholder `SECRET_KEY_BASE` | Partial: compose refuses an unset secret | None: the documented key-rotation tasks must boot with the old secret, so refusing to boot would block recovery |
| H6 | No content security policy; markdown renders remote images | Partial: no script injection | Deferred: a report-only policy without a collector protects nothing, and an enforced one needs a full audit of inline scripts and provider widgets |
| H7 | Invite email marks interpolated names as safe HTML | Confirmed | Fix |
| H8 | Backups contain `.env` unencrypted | Partial: documented in the script, permission-locked, needed for restore | None |
| H9 | SimpleFIN allows private addresses when self-hosted | Refuted: intentional, admin-only, pinned | None |
| H10 | doorkeeper, puma, rack-protection, view_component, css_parser behind patched versions | Confirmed | Update |

## Done when

Every "Fix" row has a test that failed before the change and passes after it, and the full
suite, lint and Brakeman are green.
