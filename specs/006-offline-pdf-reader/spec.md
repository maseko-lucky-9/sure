# Phase 6: offline bank PDF reader

**Status: deferred. Nothing is built.** It waits on real statements from the owner.

## Why it was planned

Sure reads a statement PDF only through an AI provider. Without one the upload is accepted and
the import fails later. The plan was a deterministic reader for Capitec and Standard Bank PDFs
behind a strict balance-reconciliation gate.

## Hypothesis, refutation and test

An independent reviewer was asked to show the build is unnecessary or premature.

| Claim | Verdict | Evidence |
| ----- | ------- | -------- |
| Sure has no offline transaction extractor | Confirmed | Text is read with `PDF::Reader#pages.map(&:text)` and handed to an AI extractor; nothing parses rows without one |
| A bank layout can be verified now | Refuted | No real statement is available. The Analyzer's own PDF engine is not wired in, and every bank profile in it is marked unverified and tested only on generated PDFs |
| A balance check on the existing AI import helps today | Refuted for this install | Test on the live app: no AI provider is configured and there are no PDF imports, so there is nothing to check |

Building bank profiles on synthetic PDFs would ship guessed layouts as if they worked. That is
the state the Analyzer's engine is in, and the reason it was never switched on.

## What would be built when samples arrive

1. A spike on one real statement: confirm `pdf-reader` gives usable text positions for that
   bank's table. If it does not, stop and report.
2. One bank profile, enabled only after it reconciles on a real statement.
3. The reconciliation gate: opening balance plus movements equals closing balance, and every
   date inside the statement period. A file that fails is refused with the reason.

Not possible in Sure today, and to be decided then: password-protected PDFs.

## What only the owner can supply

- Two or three recent statements per bank (Capitec, Standard Bank): one with several pages, one
  with fees, one that ends at a month end.
- Whether each PDF is password-protected.
- A CSV export of the same period for each PDF, as the ground truth to compare against.
- Placement in a git-ignored folder. Redaction is welcome as long as fonts, layout, dates and
  amounts are kept.

## Meanwhile

CSV exports import natively with Money In, Money Out and Fee columns (Phase 5), and the
statement converter reads CSV and Excel files.
