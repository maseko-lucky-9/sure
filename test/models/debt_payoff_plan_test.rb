require "test_helper"

class DebtPayoffPlanTest < ActiveSupport::TestCase
  # Test debts are written with plain numbers; BigDecimal via to_s keeps them exact.
  def debt(name, balance, apr, minimum)
    DebtPayoffPlan::Debt.new(name: name, balance: BigDecimal(balance.to_s), apr: BigDecimal(apr.to_s),
                             minimum_payment: BigDecimal(minimum.to_s))
  end

  def plan(debts, extra: 0, strategy: :avalanche)
    DebtPayoffPlan.new(debts: debts, extra_monthly: extra, strategy: strategy)
  end

  def payments_in(month)
    month.debts.to_h { |row| [ row.name, row.payment ] }
  end

  # -- golden cases ---------------------------------------------------------

  # 0% APR, so every figure is a plain subtraction. Snowball, extra 400:
  #   Month 1: mins A 500->400, B 1000->900. Pool 400 goes to A (smaller) -> 0.
  #            Paid 100 + 100 + 400 = 600. A is cleared.
  #   Month 2: pool = 400 extra + A's 100 minimum (rolled over) = 500.
  #            B: min 100 -> 800, pool 500 -> 300. Paid 600.
  #   Month 3: B: min 100 -> 200, pool takes the last 200 -> 0. Paid 300.
  # Without the roll-over month 2 would pay 500 and leave B at 400; the plan
  # still ends in month 3, so the month count alone cannot show it.
  test "a cleared debt's minimum rolls over into the pool from the next month" do
    result = plan([ debt("A", 500, 0, 100), debt("B", 1000, 0, 100) ], extra: 400, strategy: :snowball)

    assert_equal 3, result.months
    assert_equal %w[A B], result.payoff_order
    assert_equal BigDecimal("1500"), result.total_paid
    assert_equal BigDecimal("0"), result.total_interest

    month1, month2, month3 = result.schedule
    assert_equal({ "A" => BigDecimal("500"), "B" => BigDecimal("100") }, payments_in(month1))
    assert_equal BigDecimal("600"), month1.total_paid

    # The key assertions: A is gone, yet B receives its own 100 minimum plus
    # the full 500 pool (400 extra + A's 100).
    assert_equal [ "B" ], month2.debts.map(&:name)
    assert_equal BigDecimal("600"), payments_in(month2)["B"]
    assert_equal BigDecimal("600"), month2.total_paid
    assert_equal BigDecimal("300"), month2.debts.first.ending_balance

    assert_equal BigDecimal("900"), month1.remaining
    assert_equal BigDecimal("300"), month2.remaining
    assert_equal BigDecimal("300"), month3.total_paid
    assert_equal BigDecimal("0"), month3.remaining
    assert_equal BigDecimal("0"), month3.debts.first.ending_balance
  end

  test "a single debt at 0% APR clears in balance / minimum months with no interest" do
    result = plan([ debt("Loan", 1200, 0, 100) ])

    assert_equal 12, result.months
    assert_equal BigDecimal("0"), result.total_interest
    assert_equal BigDecimal("1200"), result.total_paid
    assert_equal [ "Loan" ], result.payoff_order
  end

  # r = 0.18 / 12 = 0.015; n = -log(1 - r * 10000 / 300) / log(1 + r)
  #   = -log(0.5) / log(1.015) = 0.6931 / 0.014889 = 46.56 -> 47 payments.
  test "a single amortising debt finishes in the standard NPER month count" do
    rate = 0.18 / 12
    expected = (-Math.log(1 - rate * 10_000 / 300.0) / Math.log(1 + rate)).ceil

    result = plan([ debt("Card", 10_000, 18, 300) ])

    assert_in_delta expected, result.months, 1
    assert_equal 47, expected
    assert_operator result.total_interest, :>, 0
    assert_equal result.total_interest + 10_000, result.total_paid
  end

  # 1000 at 12% APR, 100 minimum: interest is 1000 * 0.12 / 12 = 10.00, so
  # month 1 ends at 1000 + 10 - 100 = 910.00; month 2 accrues 9.10 and ends at
  # 819.10.
  test "interest accrues monthly on the running balance" do
    result = plan([ debt("Card", 1000, 12, 100) ])
    month1, month2 = result.schedule

    assert_equal BigDecimal("1000"), month1.debts.first.starting_balance
    assert_equal BigDecimal("10.00"), month1.interest
    assert_equal BigDecimal("910.00"), month1.debts.first.ending_balance
    assert_equal BigDecimal("9.10"), month2.interest
    assert_equal BigDecimal("819.10"), month2.debts.first.ending_balance
  end

  # 100.50 at 12% APR: 100.50 * 0.01 = 1.005 exactly, which rounds half UP to
  # 1.01 (banker's rounding would give 1.00).
  test "interest rounds half up to the cent" do
    result = plan([ debt("Card", "100.50", 12, 50) ])

    assert_equal BigDecimal("1.01"), result.schedule.first.interest
  end

  test "avalanche pays strictly less interest than snowball" do
    debts = [ debt("A", 2000, 5, 50), debt("B", 8000, 25, 200) ]

    avalanche = plan(debts, extra: 300, strategy: :avalanche)
    snowball = plan(debts, extra: 300, strategy: :snowball)

    assert_operator avalanche.total_interest, :<, snowball.total_interest
  end

  test "snowball clears the smaller balance first and avalanche the higher APR" do
    debts = [ debt("A", 2000, 5, 50), debt("B", 8000, 25, 200) ]

    assert_equal %w[A B], plan(debts, extra: 300, strategy: :snowball).payoff_order
    assert_equal %w[B A], plan(debts, extra: 300, strategy: :avalanche).payoff_order
  end

  test "ties break by name" do
    debts = [ debt("Zed", 1000, 10, 50), debt("Amy", 1000, 10, 50) ]

    first_targeted = ->(strategy) do
      result = plan(debts, extra: 500, strategy: strategy)
      payments_in(result.schedule.first).max_by { |_, paid| paid }.first
    end

    assert_equal "Amy", first_targeted.call(:avalanche)
    assert_equal "Amy", first_targeted.call(:snowball)
  end

  # A: 30 owed, 100 minimum -> pays 30, the other 70 joins the pool.
  # B: 250 -> min 100 -> 150 (paid 100), pool 70 -> 80 (paid 170). Month 2: pool = A's 100 minimum;
  # B owes 80, so its minimum is clamped to 80 and 20 is left unused.
  test "a minimum larger than the balance is clamped" do
    result = plan([ debt("A", 30, 0, 100), debt("B", 250, 0, 100) ])

    assert_equal 2, result.months
    assert_equal BigDecimal("280"), result.total_paid
    assert_equal({ "A" => BigDecimal("30"), "B" => BigDecimal("170") }, payments_in(result.schedule.first))
    assert(result.schedule.flat_map(&:debts).all? { |row| row.ending_balance >= 0 })
    assert_equal BigDecimal("0"), result.schedule.last.debts.first.ending_balance
  end

  test "identical debts are tracked separately" do
    result = plan([ debt("Card", 100, 0, 50), debt("Card", 100, 0, 50) ])

    assert_equal 2, result.months
    assert_equal [ 2, 2 ], result.schedule.map { |month| month.debts.size }
    assert_equal BigDecimal("200"), result.total_paid
  end

  test "extra money is not wasted past the last debt" do
    result = plan([ debt("A", 100, 0, 50) ], extra: 1000)

    assert_equal 1, result.months
    assert_equal BigDecimal("100"), result.total_paid
  end

  # -- edges ----------------------------------------------------------------

  test "no debts, or only zero-balance debts, means no months" do
    [ [], [ debt("Paid off", 0, 20, 25) ] ].each do |debts|
      result = plan(debts)

      assert_equal 0, result.months
      assert_equal BigDecimal("0"), result.total_interest
      assert_equal BigDecimal("0"), result.total_paid
      assert_empty result.payoff_order
      assert_empty result.schedule
      assert_nil result.debt_free_on(from: Date.new(2026, 1, 15))
    end
  end

  test "debt_free_on counts months from the given date" do
    result = plan([ debt("A", 300, 0, 100) ])

    assert_equal Date.new(2026, 4, 15), result.debt_free_on(from: Date.new(2026, 1, 15))
  end

  test "extra money lets a zero-minimum debt clear" do
    result = plan([ debt("A", 1000, 12, 0) ], extra: 500)

    assert_equal 3, result.months
  end

  # -- failures -------------------------------------------------------------

  test "a debt that gets no payment but accrues interest raises NotConverging" do
    assert_raises(DebtPayoffPlan::NotConverging) { plan([ debt("A", 1000, 12, 0) ]) }
  end

  # 10_000 at 24% accrues 200 a month; 100 a month never catches up.
  test "a minimum below the monthly interest raises NotConverging" do
    assert_raises(DebtPayoffPlan::NotConverging) { plan([ debt("A", 10_000, 24, 100) ]) }
  end

  # The pre-check only compares each debt's interest with the whole budget, so
  # this one passes it (interest 100.00 < budget 100.20) but A then shrinks so
  # slowly that it takes about 625 months (balance(t) = 10_020 - 20 * 1.01^t),
  # which the 600-month cap catches.
  test "a plan that would outlast the month cap raises NotConverging" do
    error = assert_raises(DebtPayoffPlan::NotConverging) { plan([ debt("A", 10_000, 12, "1.20"), debt("B", 1, 0, 99) ]) }

    assert_match(/600 months/, error.message)
  end

  test "negative inputs raise ArgumentError" do
    assert_raises(ArgumentError) { plan([ debt("A", -1, 5, 10) ]) }
    assert_raises(ArgumentError) { plan([ debt("A", 100, -5, 10) ]) }
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, -10) ]) }
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, 10) ], extra: -1) }
  end

  test "an unknown strategy raises ArgumentError" do
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, 10) ], strategy: :random) }
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, 10) ], strategy: nil) }
  end

  test "non-finite numbers raise ArgumentError" do
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, 10) ], extra: BigDecimal("Infinity")) }
    assert_raises(ArgumentError) { plan([ debt("A", 100, 5, 10) ], extra: BigDecimal("NaN")) }
  end

  # -- loading real debts -----------------------------------------------------

  def loaded_for(user, currency: "USD")
    DebtPayoffPlan.debts_for(user.accessible_accounts, currency: currency)
  end

  test "debts_for builds debts from loans and credit cards and lists the rest as left out" do
    loaded = loaded_for(users(:family_admin))
    by_name = loaded.debts.index_by(&:name)

    card = by_name.fetch("Credit Card")
    assert_equal BigDecimal("1000"), card.balance
    assert_equal BigDecimal("18.99"), card.apr
    assert_equal BigDecimal("100"), card.minimum_payment

    mortgage = by_name.fetch("Mortgage Loan")
    assert_equal BigDecimal("500000"), mortgage.balance
    assert_equal BigDecimal("3.5"), mortgage.apr
    assert_equal accounts(:loan).accountable.monthly_payment.amount, mortgage.minimum_payment

    assert_equal [ DebtPayoffPlan::LeftOut.new(name: "IOU (personal debt to friend)", reason: :unsupported_type) ],
                 loaded.left_out
  end

  test "debts_for leaves out a debt in another currency instead of converting it" do
    accounts(:credit_card).update_columns(currency: "EUR")

    loaded = loaded_for(users(:family_admin))

    assert_not_includes loaded.debts.map(&:name), "Credit Card"
    assert_includes loaded.left_out, DebtPayoffPlan::LeftOut.new(name: "Credit Card", reason: :other_currency)
    assert_empty loaded_for(users(:family_admin), currency: "EUR").debts.reject { |debt| debt.name == "Credit Card" }
  end

  test "debts_for leaves out a card with no APR or no minimum payment" do
    card = accounts(:credit_card).accountable

    card.update_columns(apr: nil)
    assert_includes loaded_for(users(:family_admin)).left_out, DebtPayoffPlan::LeftOut.new(name: "Credit Card", reason: :missing_apr)

    card.update_columns(apr: 18.99, minimum_payment: nil)
    assert_includes loaded_for(users(:family_admin)).left_out, DebtPayoffPlan::LeftOut.new(name: "Credit Card", reason: :missing_minimum)

    card.update_columns(minimum_payment: 0)
    assert_includes loaded_for(users(:family_admin)).left_out, DebtPayoffPlan::LeftOut.new(name: "Credit Card", reason: :missing_minimum)
  end

  # A variable-rate loan has no single contracted payment (Loan#monthly_payment
  # is nil), and no payment is invented for it.
  test "debts_for leaves out a variable-rate loan with no computable payment" do
    accounts(:loan).accountable.update_columns(rate_type: "variable")

    loaded = loaded_for(users(:family_admin))

    assert_not_includes loaded.debts.map(&:name), "Mortgage Loan"
    assert_includes loaded.left_out, DebtPayoffPlan::LeftOut.new(name: "Mortgage Loan", reason: :missing_minimum)
  end

  test "debts_for skips liabilities that owe nothing and accounts that are not visible" do
    accounts(:credit_card).update_columns(balance: -25)
    accounts(:loan).update_columns(status: "disabled")

    loaded = loaded_for(users(:family_admin))

    assert_not_includes (loaded.debts.map(&:name) + loaded.left_out.map(&:name)), "Credit Card"
    assert_not_includes (loaded.debts.map(&:name) + loaded.left_out.map(&:name)), "Mortgage Loan"
  end

  test "debts_for only sees accounts the user can access" do
    loaded = loaded_for(users(:family_member))

    assert_equal [ "Credit Card" ], loaded.debts.map(&:name)
    assert_empty loaded.left_out
  end
end
