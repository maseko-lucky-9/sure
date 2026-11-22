# Where a family's spending is heading by the end of the current month, and
# what a usual month looks like.
#
# Bills are planned spending. What they already took this month counts once at
# face value and what they still expect this month is added as it stands; only
# the rest of each parent category's spending is extrapolated at the month's
# pace. The month-end projection is shared by the spending anomaly insight and
# the Reports spending forecast, so the two can never disagree.
#
# A "usual month" is a parent category's average over the three full months
# before this one. Spending is gross of refunds. Uncategorized and Other
# investments spending is projected like any category and counts toward the
# totals (it is real spending); the anomaly insight leaves those two out of what
# it flags because they are too noisy to call a trend. A category with a bill
# still due and nothing spent yet is projected too, at the bill alone.
#
# Nothing is projected before MIN_ELAPSED_DAYS of the month have passed: too
# early in the month to extrapolate. The month follows the family's month start
# day.
#
# Totals are scoped by the income statement given, and bills still due by
# `bill_series`, so a caller reading through a shared account set passes both
# the same way.
class IncomeStatement::SpendingForecast
  MIN_ELAPSED_DAYS = 7
  BASELINE_MONTHS = 3
  # Fewer days of spending history than this and the daily spread says nothing.
  MIN_RANGE_HISTORY_DAYS = 14
  RANGE_PERCENTILES = [ 0.25, 0.75 ].freeze

  Projection = Data.define(:projected, :unplanned, :deviation_pct, :unplanned_deviation_pct)

  # One parent category's month so far, its usual month and what is still due.
  # Amounts are BigDecimal in the family's currency; `usual` is zero without a
  # baseline, and the deviations are then nil.
  CategoryForecast = Data.define(:key, :category_id, :name, :synthetic, :spent, :bills, :due, :usual, :usual_bills, :pace_factor) do
    # `planned` counts once at face value and `due` is added as it stands; only
    # the rest of the month-to-date spend is projected at the month's pace.
    def project(planned: bills)
      unplanned = (spent - planned) * pace_factor
      projected = planned + due + unplanned
      return Projection.new(projected: projected, unplanned: unplanned, deviation_pct: nil, unplanned_deviation_pct: nil) unless usual.positive?

      Projection.new(
        projected: projected,
        unplanned: unplanned,
        deviation_pct: (projected - usual) / usual * 100,
        unplanned_deviation_pct: (unplanned - (usual - usual_bills)) / usual * 100
      )
    end

    def projected
      project.projected
    end
  end

  Spread = Data.define(:low, :high)

  attr_reader :period

  def initialize(income_statement, period: nil, bill_series: nil)
    @income_statement = income_statement
    # Read once: a nightly run that crosses midnight keeps one pace throughout.
    @today = Date.current
    @period = period || Period.current_month_for(family)
    @bill_series = bill_series || default_bill_series
  end

  def available?
    elapsed_days >= MIN_ELAPSED_DAYS
  end

  def unavailable_reason
    :too_early unless available?
  end

  # The first day of the month a forecast is shown.
  def available_on
    period.start_date + (MIN_ELAPSED_DAYS - 1).days
  end

  def elapsed_days
    (@today - period.start_date).to_i + 1
  end

  # The "current month" period ends today rather than at month end, so its own
  # #days is the elapsed count and dividing by it would make the projection a
  # no-op. The month's true length comes from its start date, which is also
  # correct for families on a custom month start.
  def month_end
    period.start_date + 1.month - 1.day
  end

  def month_days
    (month_end - period.start_date).to_i + 1
  end

  def pace_factor
    month_days.to_f / elapsed_days
  end

  # { category_id => { name:, parent_id:, total:, bills: } } for persisted
  # categories with spending this month, subcategories included. `bills` is the
  # part of `total` that paid bills.
  def current_spend
    @current_spend ||= month_spend.reject { |_, data| data[:synthetic] }
                                  .to_h { |_, data| [ data[:category_id], data.slice(:name, :parent_id, :total, :bills) ] }
  end

  # Parent categories with spending or a bill due this month. Empty until
  # available?.
  def categories
    return [] unless available?

    @categories ||= begin
      current = parents_only(month_spend)
      due = bills_still_due
      baseline = baseline_spend

      (current.keys | due.keys).map do |key|
        data = current[key] || due_only_category(key)
        usual = baseline.fetch(key, nil)

        CategoryForecast.new(
          key: key, category_id: data[:category_id], name: data[:name], synthetic: data[:synthetic],
          spent: data.fetch(:total, 0.to_d), bills: data.fetch(:bills, 0.to_d), due: due.fetch(key, 0.to_d),
          usual: usual ? usual[:total] : 0.to_d, usual_bills: usual ? usual[:bills] : 0.to_d,
          pace_factor: pace_factor
        )
      end
    end
  end

  def spent_so_far
    money { categories.sum(&:spent) }
  end

  def projected_total
    money { categories.sum(&:projected) }
  end

  # The same baseline the categories compare against, summed over every parent
  # category that had spending in it.
  def usual_total
    money { baseline_spend.values.sum { |usual| usual[:total] } }
  end

  # Whether the family has history across all the baseline months. Without it
  # the usual month is averaged over months with nothing in them, reads far too
  # low, and makes an ordinary month look like a blowout.
  def usual_known?
    history_start.present? && history_start <= period.start_date - BASELINE_MONTHS.months
  end

  # Where the month is likely to end: spending outside bills so far, plus the
  # remaining days at the 25th and 75th percentile of a day's spending in the
  # last three months, plus the bills paid and still due as known amounts. Never
  # below what is already spent, and widened to take in the projection when
  # this month's pace sits outside the usual daily spread. Daily totals include
  # bill payments, so the spread leans a little wide. Nil with less than
  # MIN_RANGE_HISTORY_DAYS of spending history to read the spread from.
  def range
    return nil unless available?
    return @range if defined?(@range)

    @range = build_range
  end

  def as_json(*)
    {
      available: available?,
      unavailable_reason: unavailable_reason&.to_s,
      currency: family.currency,
      period: { start_date: period.start_date.iso8601, end_date: month_end.iso8601 },
      spent_so_far: amount_json(spent_so_far),
      projected_total: amount_json(projected_total),
      usual_total: usual_known? ? amount_json(usual_total) : nil,
      range: range && { low: amount_json(range.low), high: amount_json(range.high) }
    }
  end

  private
    attr_reader :income_statement, :bill_series

    def family
      income_statement.family
    end

    # Bills on the accounts the statement reads its spending from, so a bill
    # still due is never counted where its payments would not be.
    def default_bill_series
      RecurringTransaction.within_accounts(income_statement.eligible_accounts)
    end

    def history_start
      return @history_start if defined?(@history_start)

      @history_start = IncomeStatement::SpendingComparison.history_start(income_statement)
    end

    def money
      return nil unless available?

      Money.new(yield, family.currency)
    end

    def amount_json(money)
      money && money.amount.to_d.to_s("F")
    end

    def build_range
      history_days, daily_totals = baseline_daily_totals
      return nil if history_days < MIN_RANGE_HISTORY_DAYS

      low_pct, high_pct = RANGE_PERCENTILES.map { |fraction| percentile(daily_totals, fraction) }
      remaining_days = month_days - elapsed_days
      known = categories.sum(&:bills) + categories.sum(&:due) + categories.sum { |c| c.spent - c.bills }
      spent = categories.sum(&:spent)
      projected = categories.sum(&:projected)

      low = [ [ known + remaining_days * low_pct, projected ].min, spent ].max
      high = [ known + remaining_days * high_pct, projected, low ].max
      Spread.new(low: Money.new(low, family.currency), high: Money.new(high, family.currency))
    end

    # [days of history, sorted daily totals] over the baseline months, from the
    # first day the family could have spent anything. Days without spending are
    # zeros, not missing.
    def baseline_daily_totals
      window_start = period.start_date - BASELINE_MONTHS.months
      window_end = period.start_date - 1.day
      return [ 0, [] ] unless history_start

      first_day = [ history_start, window_start ].max
      history_days = (window_end - first_day).to_i + 1
      return [ 0, [] ] if history_days < 1

      series = income_statement.daily_expense_series(period: Period.custom(start_date: first_day, end_date: window_end))
      by_date = series.to_h { |day| [ day.date, day.total.to_d ] }

      [ history_days, (first_day..window_end).map { |date| by_date.fetch(date, 0.to_d) }.sort ]
    end

    # Linear interpolation between the closest ranks.
    def percentile(sorted, fraction)
      rank = fraction * (sorted.size - 1)
      lower = sorted[rank.floor]
      upper = sorted[rank.ceil]
      lower + (upper - lower) * (rank - rank.floor).to_d
    end

    # { key => { category_id:, name:, parent_id:, synthetic:, total:, bills: } }
    # for categories with spending in the period, gross of refunds. Persisted
    # categories are keyed by id and the two synthetic ones by name.
    def spend_by_category(for_period)
      bills = income_statement.bill_expense_totals(period: for_period).category_totals.to_h { |ct| [ key_for(ct.category), ct.total.to_d ] }

      income_statement.expense_totals(period: for_period).category_totals.each_with_object({}) do |ct, totals|
        next unless ct.total.positive?

        key = key_for(ct.category)
        totals[key] = { category_id: ct.category.id, name: ct.category.name, parent_id: ct.category.parent_id,
                        synthetic: ct.category.synthetic?, total: ct.total.to_d, bills: bills.fetch(key, 0.to_d) }
      end
    end

    def month_spend
      @month_spend ||= spend_by_category(period)
    end

    # Only parent categories are projected: subcategory spend is already rolled
    # into its parent's total.
    def parents_only(spend)
      spend.reject { |_, data| data[:parent_id] }
    end

    def baseline_spend
      @baseline_spend ||= begin
        sums = Hash.new { |h, k| h[k] = { total: 0.to_d, bills: 0.to_d } }

        BASELINE_MONTHS.times do |i|
          start_date = period.start_date - (i + 1).months
          month = Period.custom(start_date: start_date, end_date: start_date + 1.month - 1.day)

          parents_only(spend_by_category(month)).each do |key, data|
            sums[key][:total] += data[:total]
            sums[key][:bills] += data[:bills]
          end
        end

        sums.transform_values { |usual| usual.transform_values { |amount| amount / BASELINE_MONTHS } }
      end
    end

    # What bills still expect this month, by parent category key, in the
    # family's currency. Filed under the bill's own category, since there is no
    # entry yet to take one from. One with no rate is left out, as unplanned
    # spending would be.
    def bills_still_due
      parent_ids = category_parents

      RecurringOccurrence.open_bills_due(family, period.start_date..month_end, series: bill_series).each_with_object(Hash.new(0.to_d)) do |occurrence, sums|
        category_id = occurrence.recurring_transaction.category_id
        key = category_id.nil? ? :uncategorized : (parent_ids[category_id] || category_id)
        sums[key] += occurrence.remaining_spending_money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        next
      end
    end

    def category_parents
      family_categories.transform_values(&:last)
    end

    # { id => [name, parent_id] }
    def family_categories
      @family_categories ||= family.categories.pluck(:id, :name, :parent_id).to_h { |id, name, parent_id| [ id, [ name, parent_id ] ] }
    end

    # A category with a bill due but nothing spent yet this month.
    def due_only_category(key)
      return { category_id: nil, name: Category.uncategorized_name, synthetic: true } if key == :uncategorized

      { category_id: key, name: family_categories.fetch(key).first, synthetic: false }
    end

    def key_for(category)
      return :uncategorized if category.uncategorized?
      return :other_investments if category.other_investments?

      category.id
    end
end
