# Phase 3: South African tuning

## Why

Sure's defaults assume dollar- or euro-scale money and North American or European tax wrappers.
Three things stop it fitting a South African household.

## Hypotheses, refutation and tests

An independent reviewer was asked to show each gap does not exist.

| Feature | Verdict | What Sure already has | What is missing |
| ------- | ------- | --------------------- | --------------- |
| Rand-scaled thresholds | Confirmed | "Known limitation" comments on each threshold | Any scale: `config/currencies.yml` has no usable field and families have no threshold settings |
| Tax-free savings caps | Partial | Investment and depository subtypes with tax treatment; `tfsa` exists but is Canadian | A South African subtype, and any tracking of contributions against a cap |
| 50/30/20 | Partial | Income and expense totals per category for the family's month | Any needs / wants / savings classification of categories |

The reviewer also found three money thresholds outside the insight generators with the same
limitation: `Goal::WithdrawalDetector`, the weekly cleanup's missing-context detector and the
recurring-transaction subscription ceiling.

## Tax-free savings limits

From the SARS tax-free investments page, read on 22 November 2026. A year of assessment ends in
February of the year it is named for.

| Year of assessment | Annual limit |
| ------------------ | ------------ |
| 2016 to 2017 | R30 000 |
| 2018 to 2020 | R33 000 |
| 2021 to 2026 | R36 000 |
| 2027 onward | R46 000 |

- Lifetime limit: R500 000 per person.
- Excess over either limit is taxed at 40%.
- Returns left in the account do not count. Money withdrawn and reinvested counts as a new
  contribution, so a withdrawal does not restore room.

The Personal Finance Analyzer still uses R36 000 and clamps to R3 000 a month.

Assumption: a transfer between two tax-free accounts is not a contribution. The SARS page says
only that such transfers have been allowed since 1 March 2018.

## Improvements over the Analyzer

- Thresholds scale by a static integer per currency, so other currencies are unchanged.
- Contributions are counted per tax year against that year's limit; the Analyzer has no tax year.
- 50/30/20 takes income from the family's own income statement and shows unassigned categories
  rather than dropping them.
