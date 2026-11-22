# Looks back at the last two finished months and names where spending ran above
# the family's own normal (see IncomeStatement::SpendingComparison) in both:
# the parent categories at least MIN_RISE_PCT above normal each month, the
# three furthest above. The saving is what going back to normal in those
# categories would keep each month, shown as one insight per month rather than
# one per category.
#
# Two months, not one, so a single large purchase is never reported as a
# monthly saving; the smaller of the two overages is the amount claimed.
#
# The current, unfinished month's pace is SpendingAnomalyGenerator's; this one
# only reads months that are over. It is never high priority: a look back is
# not urgent, and high priority sends a push notification.
class Insight::Generators::SavingsOpportunityGenerator < Insight::Generator
  produces "savings_opportunity"

  MIN_RISE_PCT = 10
  MAX_CATEGORIES = 3
  # A relative floor, deliberately not a money amount, so it holds in any
  # currency: a share of the month's normal total spending.
  MIN_SAVING_PCT = 5
  BUCKET_PCT = 5
  # "Normal" read from less history than this is one or two months restated.
  MIN_BASELINE_DAYS = 180
  # Last-day transactions arrive late (pending rows, a sync still to run), and
  # each one would redraw the figures on a card the family has already seen.
  SETTLE_DAYS = 3

  Overage = Data.define(:category, :amount)

  def generate
    period = Period.last_month_for(family)
    return [] if Date.current < period.end_date + SETTLE_DAYS.days

    latest = comparison_for(period)
    earlier = comparison_for(Period.custom(start_date: period.start_date - 1.month, end_date: period.start_date - 1.day))
    return [] unless [ latest, earlier ].all? { |comparison| enough_history?(comparison) }

    normal_total = latest.normal_total
    return [] unless normal_total&.positive?

    overages = persistent_overages(latest, earlier)
    return [] if overages.empty?

    saving = overages.sum(&:amount)
    return [] if saving * 100 < normal_total * MIN_SAVING_PCT

    [
      build_insight(
        insight_type: "savings_opportunity",
        priority: "medium",
        title: I18n.t("insights.titles.savings_opportunity", saving: format_money(saving)),
        template_key: "savings_opportunity",
        facts: {
          saving: format_money(saving),
          count: overages.size,
          categories: overages.map { |overage| "#{overage.category.name} (#{format_money(overage.amount)})" }.to_sentence
        },
        # The months are over, so the figures only move when a late transaction
        # is imported or edited. Like SpendingAnomalyGenerator's deviation
        # bucket, the saving is bucketed (here as a share of normal spending,
        # which needs no currency scale) so such a trivial recalculation
        # doesn't reopen an acknowledged card; the display amounts live in
        # `facts` only.
        metadata: {
          saving_bucket: (saving * 100 / normal_total / BUCKET_PCT).floor * BUCKET_PCT,
          accounts_digest: shared_accounts_digest
        },
        period: period,
        dedup_key: "savings_opportunity:#{month_token(period.start_date)}"
      )
    ]
  end

  private
    def comparison_for(period)
      @history_start = IncomeStatement::SpendingComparison.history_start(income_statement) unless defined?(@history_start)

      IncomeStatement::SpendingComparison.new(income_statement, period: period, history_start: @history_start)
    end

    def enough_history?(comparison)
      comparison.comparable? && comparison.baseline_period.days >= MIN_BASELINE_DAYS
    end

    # Parent categories above normal in both months, each at the smaller of its
    # two overages, largest first. The synthetic rows (Uncategorized, Other
    # investments) aren't something the family can decide to spend less on.
    def persistent_overages(latest, earlier)
      before = above_normal(earlier).index_by { |row| row.category.id }

      above_normal(latest).filter_map do |row|
        previous = before[row.category.id]
        Overage.new(category: row.category, amount: [ row.change, previous.change ].min) if previous
      end.sort_by { |overage| -overage.amount }.first(MAX_CATEGORIES)
    end

    def above_normal(comparison)
      comparison.rows
        .reject { |row| row.category.synthetic? }
        .select { |row| row.normal&.positive? && row.change * 100 >= row.normal * MIN_RISE_PCT }
    end
end
