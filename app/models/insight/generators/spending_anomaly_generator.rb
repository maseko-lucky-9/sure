# Flags parent categories whose current-month spending pace deviates from
# their average over the previous three full months.
#
# Bills are planned spending. What they already took this month counts once at
# face value and what they still expect this month is added as it stands; only
# the rest is projected at the month's pace. A category is flagged only when
# its spending outside bills moves too, so a bill that changes the month (an
# annual premium, a payment that fell in the previous month) is not a trend.
class Insight::Generators::SpendingAnomalyGenerator < Insight::Generator
  produces "spending_anomaly"

  # Ignore categories with a negligible baseline: a dollar-scale base, scaled
  # by Money::Scale for the family's currency.
  MIN_BASELINE = 50
  DEVIATION_THRESHOLD_PCT = 25
  HIGH_PRIORITY_PCT = 50
  MAX_INSIGHTS = 3

  def generate
    forecast = IncomeStatement::SpendingForecast.new(income_statement, bill_series: shared_recurring_transactions)
    return [] unless forecast.available?

    @current_spend = forecast.current_spend
    # Nothing spent, nothing to flag: skip reading the baseline and the bills.
    return [] if @current_spend.empty?

    current = forecast.categories.select { |category| !category.synthetic && category.spent.positive? }
    return [] if current.empty?

    anomalies = current.filter_map do |category|
      next unless category.usual >= scaled(MIN_BASELINE)

      projection = category.project
      next unless significant?(projection.deviation_pct, projection.unplanned_deviation_pct)
      next if projection.deviation_pct.positive? && paid_from_rollover?(category)

      { category_id: category.category_id, name: category.name, projected: projection.projected,
        baseline: category.usual, deviation_pct: projection.deviation_pct }
    end

    anomalies
      .sort_by { |a| -a[:deviation_pct].abs }
      .first(MAX_INSIGHTS)
      .map { |anomaly| anomaly_insight(anomaly, forecast.period) }
  end

  private
    def anomaly_insight(anomaly, period)
      direction = anomaly[:deviation_pct].positive? ? "above" : "below"

      build_insight(
        insight_type: "spending_anomaly",
        priority: anomaly[:deviation_pct].abs >= HIGH_PRIORITY_PCT ? "high" : "medium",
        title: I18n.t("insights.titles.spending_anomaly.#{direction}", category: anomaly[:name]),
        template_key: "spending_anomaly.#{direction}",
        facts: {
          category: anomaly[:name],
          deviation_pct: round(anomaly[:deviation_pct].abs, 0).to_i,
          projected_spend: format_money(anomaly[:projected]),
          baseline_spend: format_money(anomaly[:baseline])
        },
        # The projection moves every night by construction (spend accrues and
        # the pace factor shrinks as the month elapses), so exact amounts here
        # would rewrite the body and resurrect dismissals nightly. Bucket the
        # deviation instead; the display numbers live in `facts` only.
        metadata: {
          category_id: anomaly[:category_id],
          direction: direction,
          deviation_bucket: (round(anomaly[:deviation_pct].abs, 0).to_i / 25) * 25,
          accounts_digest: shared_accounts_digest
        },
        period: period,
        dedup_key: "spending_anomaly:#{anomaly[:category_id]}:#{month_token(period.start_date)}"
      )
    end

    # Both the whole projection and its unplanned part have to clear the
    # threshold in the same direction.
    def significant?(deviation_pct, unplanned_deviation_pct)
      [ deviation_pct, unplanned_deviation_pct ].all? { |pct| pct.abs >= DEVIATION_THRESHOLD_PCT } &&
        deviation_pct.positive? == unplanned_deviation_pct.positive?
    end

    # Money saved up in a rollover envelope is there to be spent in a lump.
    # Counted as planned, like a bill, does the rise still stand? The envelope
    # may be the parent's or a ring-fenced subcategory's (Insurance under
    # Home), as long as it isn't overspent. Only the household budget counts.
    def paid_from_rollover?(category)
      return false unless current_budget&.initialized?

      category_id = category.category_id

      envelopes = current_budget.budget_categories.select do |bc|
        (bc.category_id == category_id || bc.category.parent_id == category_id) &&
          bc.rollover_enabled? && !bc.inherits_parent_budget? && !bc.over_budget?
      end
      saved = envelopes.sum { |bc| drawn_from_savings(bc, category.pace_factor) }
      return false unless saved.positive?

      planned = [ category.bills + saved, category.spent ].min
      projection = category.project(planned: planned)
      !(projection.deviation_pct.positive? && significant?(projection.deviation_pct, projection.unplanned_deviation_pct))
    end

    # What an envelope has spent outside bills beyond its own allocation to
    # date, up to what it carried over: the part that came out of savings.
    # Spending within the month's allocation is ordinary spending, whatever
    # cushion sits behind it. Bills are already planned in the category's own `bills`, and
    # a parent leaves its ring-fenced subcategories to their own envelopes.
    # Spending is read gross of refunds, as the category's own is.
    def drawn_from_savings(envelope, pace_factor)
      spent, allocated = outside_bills(envelope)
      envelope.subcategories.reject(&:inherits_parent_budget?).each do |fenced|
        fenced_spent, fenced_allocated = outside_bills(fenced)
        spent -= fenced_spent
        allocated -= fenced_allocated
      end

      (spent - allocated.clamp(0, nil) / pace_factor).clamp(0, envelope.rolled_over_amount.to_d)
    end

    # [spent, allocated] for a budget line this month, less the bills it paid.
    def outside_bills(budget_category)
      spend = @current_spend.fetch(budget_category.category_id, { total: 0, bills: 0 })
      [ spend[:total], budget_category.budgeted_spending.to_d ].map { |amount| amount - spend[:bills] }
    end
end
