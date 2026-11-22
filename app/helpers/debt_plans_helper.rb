module DebtPlansHelper
  # Amounts in a debt plan are plain BigDecimals in the family's currency;
  # format_money would otherwise read a bare number in the default currency.
  def debt_plan_money(amount, currency)
    format_money(Money.new(amount, currency))
  end

  # The calendar month a plan month falls in, counting month 1 as one month
  # from today, as DebtPayoffPlan#debt_free_on does.
  def debt_plan_month_label(month_number, from: Date.current)
    l(from.next_month(month_number), format: :short_month_year)
  end
end
