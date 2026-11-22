class DebtPlansController < ApplicationController
  before_action :require_preview_features!

  # Beyond this an amount is not a real monthly figure; treated like garbage.
  MAX_EXTRA = 1_000_000_000

  def show
    @currency = Current.family.primary_currency_code
    @strategy = strategy_param
    @extra = extra_param

    loaded = DebtPayoffPlan.debts_for(Current.user.accessible_accounts, currency: @currency)
    @debts = loaded.debts
    @left_out = loaded.left_out

    # Both strategies are planned so the page can show the trade-off; a
    # strategy that cannot finish is nil rather than an error for the page.
    @plans = DebtPayoffPlan::STRATEGIES.index_with { |strategy| plan_for(strategy) }
    @plan = @plans[@strategy.to_sym]

    @breadcrumbs = plan_breadcrumb_prefix + [ [ t("debt_plans.show.title"), nil ] ]
  end

  private
    def strategy_param
      requested = params[:strategy].to_s
      DebtPayoffPlan::STRATEGIES.map(&:to_s).include?(requested) ? requested : DebtPayoffPlan::STRATEGIES.first.to_s
    end

    def extra_param
      amount = BigDecimal(params[:extra].to_s.strip, exception: false)
      return BigDecimal("0") unless amount&.finite? && !amount.negative? && amount <= MAX_EXTRA

      amount.round(2)
    end

    def plan_for(strategy)
      DebtPayoffPlan.new(debts: @debts, extra_monthly: @extra, strategy: strategy)
    rescue DebtPayoffPlan::NotConverging
      nil
    end
end
