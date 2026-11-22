# Phase 1: statement converter

## Why

South African bank exports use separate Money In, Money Out and Fee columns. Sure's transaction
import has two amount strategies, `signed_amount` and `custom_column`, and neither reads that
layout.

## Hypothesis and test

**Hypothesis:** a stock `TransactionImport` cannot read a Money In / Money Out / Fee file.

**Test:** import the 10-row fixture with `amount_col_label: "Money In"`.

**Result on `main`:** `rows=10 valid=4`. Every money-out row and every fee had a blank amount;
the row with both columns kept only its inflow. Hypothesis confirmed.

## What it delivers

A dependency-free script outside the Rails app that converts such a file and pushes it through
the existing imports API. It is a stopgap until Phase 5 adds the layout to Sure's own import.

## Done when

The converted fixture imports through `TransactionImport` with every row valid, the signs
correct, and a second import adding nothing.
