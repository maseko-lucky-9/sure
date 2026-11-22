require "test_helper"

class IncomeStatement::NeedsWantsSavingsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new)
    @period = Period.custom(start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30))

    @salary = category("Salary")
    @groceries = category(I18n.t("models.category.defaults.groceries"))
    @mortgage = category(I18n.t("models.category.defaults.mortgage_rent"))
    @entertainment = category(I18n.t("models.category.defaults.entertainment"))
    @streaming = category("Streaming", parent: @entertainment)
    @shopping = category(I18n.t("models.category.defaults.shopping"))
    @savings = category(I18n.t("models.category.defaults.savings_and_investments"))
    @side_hustle = category("Side hustle costs")
  end

  test "targets are 50/30/20" do
    assert_equal({ needs: 50, wants: 30, savings: 20 }, IncomeStatement::NeedsWantsSavings::TARGETS)
  end

  test "splits spending into needs, wants, savings and unassigned, with unspent income counted as savings" do
    spend(-5000, @salary)
    spend(1200.55, @groceries)
    spend(1000, @mortgage)
    spend(700, @entertainment)
    spend(100, @streaming) # inside Entertainment's total already
    spend(400, @shopping)
    spend(300, @savings)
    spend(150, @side_hustle)
    spend(50, nil) # Uncategorized

    result = build

    assert_predicate result, :available?
    assert_equal BigDecimal("5000"), result.income
    assert_equal BigDecimal("1099.45"), result.leftover

    assert_row result.needs, amount: "2200.55", share: "44.0", target_share: 50, target_amount: "2500", difference: "-299.45"
    assert_row result.wants, amount: "1200", share: "24.0", target_share: 30, target_amount: "1500", difference: "-300"
    # 300 in savings categories + 1099.45 left unspent
    assert_row result.savings, amount: "1399.45", share: "28.0", target_share: 20, target_amount: "1000", difference: "399.45"

    assert_equal BigDecimal("200"), result.unassigned.amount
    assert_equal BigDecimal("4.0"), result.unassigned.share
    assert_equal [ [ "Side hustle costs", BigDecimal("150") ], [ "Uncategorized", BigDecimal("50") ] ],
                 result.unassigned.categories.map { |c| [ c.name, c.amount ] }
  end

  test "needs, wants, savings and unassigned add up to income exactly" do
    spend(-5000.01, @salary)
    spend(1200.55, @groceries)
    spend(333.33, @mortgage)
    spend(700.07, @entertainment)
    spend(99.99, @streaming)
    spend(400.1, @shopping)
    spend(300.3, @savings)
    spend(150.15, @side_hustle)
    spend(49.99, nil)

    result = build
    total = result.needs.amount + result.wants.amount + result.savings.amount + result.unassigned.amount

    assert_equal result.income, total
    [ result.income, result.needs.amount, result.wants.amount, result.savings.amount, result.unassigned.amount,
      result.leftover ].each { |figure| assert_kind_of BigDecimal, figure }
  end

  test "a subcategory's spending is counted once, in its parent's bucket" do
    spend(-1000, @salary)
    spend(100, @streaming)

    result = build

    assert_equal BigDecimal("100"), result.wants.amount
    # Savings is only what was left: counting the subcategory row too would give 800.
    assert_equal BigDecimal("900"), result.savings.amount
    assert_equal BigDecimal("0"), result.unassigned.amount
  end

  test "a category's own bucket moves its spending" do
    @groceries.update!(budget_bucket: "wants")
    spend(-1000, @salary)
    spend(100, @groceries)

    result = build

    assert_equal BigDecimal("0"), result.needs.amount
    assert_equal BigDecimal("100"), result.wants.amount
  end

  test "a category with no bucket is unassigned, never wants" do
    spend(-1000, @salary)
    spend(80, @side_hustle)

    result = build

    assert_equal BigDecimal("80"), result.unassigned.amount
    assert_equal BigDecimal("0"), result.wants.amount
    assert_equal [ "Side hustle costs" ], result.unassigned.categories.map(&:name)
  end

  test "unassigned categories are listed largest first" do
    small = category("Small one")
    big = category("Big one")
    spend(-1000, @salary)
    spend(10, small)
    spend(90, big)

    assert_equal [ "Big one", "Small one" ], build.unassigned.categories.map(&:name)
  end

  test "overspending makes the savings amount negative" do
    spend(-1000, @salary)
    spend(1500, @groceries)

    result = build

    assert_equal BigDecimal("-500"), result.leftover
    assert_equal BigDecimal("-500"), result.savings.amount
    assert_equal BigDecimal("-50.0"), result.savings.share
    assert_equal BigDecimal("-700"), result.savings.difference
    assert_equal BigDecimal("150.0"), result.needs.share
    assert_equal result.income, result.needs.amount + result.wants.amount + result.savings.amount + result.unassigned.amount
  end

  test "without income there is nothing to compare" do
    spend(100, @groceries)

    result = build

    assert_not result.available?
    assert_empty result.rows
  end

  test "income that is not positive is not available" do
    assert_not IncomeStatement::NeedsWantsSavings.new(groups: [], currency: "USD").available?
  end

  # 1,000 of groceries with 200 refunded is 800 of needs, and the refund is not
  # income: 800 of 5,000 is 16%, not 1,000 of 5,200.
  test "a refund comes off its category's spending and is not income" do
    spend(-5000, @salary)
    spend(1000, @groceries)
    spend(-200, @groceries)

    result = build

    assert_equal BigDecimal("5000"), result.income
    assert_row result.needs, amount: "800", share: "16.0", target_share: 50, target_amount: "2500", difference: "-1700"
    assert_equal BigDecimal("4200"), result.savings.amount
  end

  test "a reversal inside an income category reduces income and is not spending" do
    spend(-1000, @salary)
    spend(50, @salary)

    result = build

    assert_equal BigDecimal("950"), result.income
    assert_equal BigDecimal("0"), result.unassigned.amount
    assert_equal BigDecimal("950"), result.savings.amount
  end

  test "rows come in needs, wants, savings order" do
    spend(-1000, @salary)

    assert_equal %i[needs wants savings], build.rows.map(&:bucket)
  end

  private
    def category(name, **attributes)
      @family.categories.create!(name: name, color: "#123456", lucide_icon: "shapes", **attributes)
    end

    def spend(amount, category)
      create_transaction(account: @account, date: Date.new(2026, 9, 10), amount: amount, category: category)
    end

    def build
      groups = IncomeStatement::CategoryNetting.new(IncomeStatement.new(@family), period: @period).groups
      IncomeStatement::NeedsWantsSavings.new(groups: groups, currency: @family.currency)
    end

    def assert_row(row, amount:, share:, target_share:, target_amount:, difference:)
      assert_equal BigDecimal(amount), row.amount
      assert_equal BigDecimal(share), row.share
      assert_equal target_share, row.target_share
      assert_equal BigDecimal(target_amount), row.target_amount
      assert_equal BigDecimal(difference), row.difference
    end
end
