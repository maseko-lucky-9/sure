require "test_helper"

class IncomeStatement::SpendingForecastTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # September 2026 has 30 days, so on the 10th the month's pace is 3.
  TODAY = Date.new(2026, 9, 10)

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new)
    @food = @family.categories.create!(name: "Food")
    @housing = @family.categories.create!(name: "Housing")
    @insurance = @family.categories.create!(name: "Insurance")
  end

  test "projects each category at the month's pace and sums them" do
    travel_to TODAY do
      seed_month_with_bills

      forecast = forecast_for_today
      by_name = forecast.categories.index_by(&:name)

      assert_equal 300, by_name["Food"].projected # 100 spent in 10 days of 30
      assert_equal 1_000, by_name["Housing"].projected # rent paid counts once, not tripled
      assert_equal 500, by_name["Insurance"].projected # nothing spent yet, a bill still due
      assert_equal 120, by_name[Category.uncategorized_name].projected # 40 spent, uncategorized counts too
      assert_equal 3.0, forecast.pace_factor
      assert_equal money(1_920), forecast.projected_total
      assert_equal forecast.categories.sum(&:projected), forecast.projected_total.amount
      assert_equal money(1_140), forecast.spent_so_far
    end
  end

  test "a usual month is the same baseline the categories compare against" do
    travel_to TODAY do
      seed_month_with_bills

      forecast = forecast_for_today

      # Food 300 + Housing 1,000; the uncategorized spend and the insurance had none
      assert_equal money(1_300), forecast.usual_total
      assert_equal money(1_300), money(forecast.categories.sum(&:usual))
    end
  end

  test "agrees with the figures the spending anomaly insight reports" do
    # The insight reads only accounts every active member can see
    @family.users.where.not(id: @account.owner_id).each { |user| AccountShare.create!(account: @account, user: user, permission: "read_only") }

    travel_to TODAY do
      rent = create_bill(category: @housing, amount: 1_000, name: "Rent", day: 3, account: @account)
      water = create_bill(category: @housing, amount: 200, name: "Water", day: 25, account: @account)
      [ Date.new(2026, 6, 1), Date.new(2026, 7, 1), Date.new(2026, 8, 1), Date.new(2026, 9, 1) ].each do |month|
        pay_bill(rent, date: month.change(day: 3))
      end
      [ 6, 7, 8 ].each { |m| spend(@housing, 100, Date.new(2026, m, 12)) }
      spend(@housing, 400, Date.new(2026, 9, 5))
      expect_bill(water, due_on: Date.new(2026, 9, 25))

      facts = Insight::Generators::SpendingAnomalyGenerator.new(@family).generate.sole.facts
      housing = forecast_for_today.categories.find { |category| category.name == "Housing" }

      assert_equal 2_400, housing.projected # 1,000 rent + 200 due + 400 * 3
      assert_equal money(housing.projected).format, facts[:projected_spend]
      assert_equal money(housing.usual).format, facts[:baseline_spend]
    end
  end

  test "ranges over the usual daily spread of the last three months" do
    travel_to TODAY do
      seed_daily_spending

      range = forecast_for_today.range

      # 250 spent so far, 20 days left. Days 1-10 of the baseline months cost 40
      # and the rest 10, so the 25th percentile is 10 and the 75th is 40.
      assert_equal money(250 + 20 * 10), range.low
      assert_equal money(250 + 20 * 40), range.high
      assert_equal money(750), forecast_for_today.projected_total
      assert_operator range.low.amount, :<=, 750
      assert_operator 750, :<=, range.high.amount
    end
  end

  test "the range stretches to the projection when this month runs past the usual spread" do
    travel_to TODAY do
      seed_daily_spending
      spend(@food, 1_000, Date.new(2026, 9, 9))

      forecast = forecast_for_today
      range = forecast.range

      assert_operator forecast.projected_total.amount, :>, 250 + 20 * 40 + 1_000
      assert_equal forecast.projected_total, range.high
      assert_operator range.low.amount, :>=, forecast.spent_so_far.amount
    end
  end

  test "bills count as known amounts at both ends of the range" do
    travel_to TODAY do
      seed_daily_spending
      water = create_bill(category: @housing, amount: 200, name: "Water", day: 25, account: @account)
      expect_bill(water, due_on: Date.new(2026, 9, 25))

      range = forecast_for_today.range

      assert_equal money(250 + 200 + 20 * 10), range.low
      assert_equal money(250 + 200 + 20 * 40), range.high
    end
  end

  test "has no range with too little spending history" do
    travel_to TODAY do
      spend(@food, 30, Date.new(2026, 8, 25)) # the first spending, seven days before the baseline ends
      Date.new(2026, 9, 1).upto(Date.new(2026, 9, 10)) { |day| spend(@food, 25, day) }

      forecast = forecast_for_today

      assert forecast.available?
      assert_nil forecast.range
      assert_equal money(750), forecast.projected_total
      assert_nil forecast.as_json[:range]
    end
  end

  test "has no range without any spending history" do
    travel_to TODAY do
      assert_nil forecast_for_today.range
    end
  end

  test "projects nothing before the month is seven days old" do
    travel_to Date.new(2026, 9, 6) do
      spend(@food, 100, Date.new(2026, 9, 2))

      forecast = forecast_for_today

      assert_not forecast.available?
      assert_equal :too_early, forecast.unavailable_reason
      assert_empty forecast.categories
      assert_nil forecast.projected_total
      assert_nil forecast.usual_total
      assert_nil forecast.spent_so_far
      assert_nil forecast.range
      assert_equal({ available: false, unavailable_reason: "too_early" }, forecast.as_json.slice(:available, :unavailable_reason))
    end

    travel_to Date.new(2026, 9, 7) do
      assert forecast_for_today.available?
      assert_nil forecast_for_today.unavailable_reason
    end
  end

  test "follows the family's month start day" do
    @family.update!(month_start_day: 15)

    travel_to Date.new(2026, 9, 25) do
      spend(@food, 500, Date.new(2026, 9, 5)) # last family month: Aug 15 - Sep 14
      spend(@food, 110, Date.new(2026, 9, 16)) # this one: Sep 15 - Oct 14, 11 days in

      forecast = forecast_for_today

      assert_equal Date.new(2026, 9, 15), forecast.period.start_date
      assert_equal Date.new(2026, 10, 14), forecast.month_end
      assert_equal 11, forecast.elapsed_days
      assert_equal 30, forecast.month_days
      assert_equal money(110), forecast.spent_so_far
      assert_in_delta 110 * 30 / 11r, forecast.projected_total.amount, 1e-9
      # The Sep 5 spending falls in one of the three baseline months
      assert_in_delta 500 / 3r, forecast.usual_total.amount, 1e-9
    end
  end

  test "bills outside the given series are left out" do
    travel_to TODAY do
      seed_month_with_bills

      forecast = forecast_for_today(bill_series: RecurringTransaction.none)

      assert_not forecast.categories.any? { |category| category.name == "Insurance" }
      assert_equal money(1_420), forecast.projected_total
    end
  end

  test "bills on accounts the statement does not read are left out" do
    travel_to TODAY do
      seed_month_with_bills
      hidden = @family.accounts.create!(name: "Business", currency: @family.currency, balance: 0, accountable: Depository.new, exclude_from_reports: true)
      create_bill(category: @food, amount: 400, name: "Software", day: 20, account: hidden).tap { |bill| expect_bill(bill, due_on: Date.new(2026, 9, 20)) }

      forecast = forecast_for_today

      assert_equal money(1_920), forecast.projected_total # Food stays 100 * 3, the 400 is not counted
    end
  end

  # Averaged over three months regardless, a newer family's usual month reads
  # far too low and an ordinary month looks like a blowout.
  test "a usual month is only stated with all three baseline months of history" do
    travel_to TODAY do
      spend(@food, 300, Date.new(2026, 8, 15))
      spend(@food, 100, Date.new(2026, 9, 4))

      assert_not forecast_for_today.usual_known?
      assert_nil forecast_for_today.as_json[:usual_total]

      spend(@food, 300, Date.new(2026, 6, 1))

      assert forecast_for_today.usual_known?
      assert_in_delta 200, BigDecimal(forecast_for_today.as_json[:usual_total]), 1e-9 # (300 + 300) / 3
    end
  end

  test "reads today once, so a run across midnight keeps one pace" do
    travel_to TODAY
    forecast = forecast_for_today
    travel_to TODAY + 1.day

    assert_equal 10, forecast.elapsed_days
  ensure
    travel_back
  end

  test "knows the day the forecast starts" do
    travel_to TODAY do
      assert_equal Date.new(2026, 9, 7), forecast_for_today.available_on
    end

    @family.update!(month_start_day: 15)
    travel_to Date.new(2026, 9, 25) do
      assert_equal Date.new(2026, 9, 21), forecast_for_today.available_on
    end
  end

  test "as_json gives decimal strings in the family currency" do
    travel_to TODAY do
      seed_daily_spending

      json = forecast_for_today.as_json

      assert_equal({ available: true, unavailable_reason: nil, currency: @family.currency,
                     period: { start_date: "2026-09-01", end_date: "2026-09-30" },
                     spent_so_far: "250.0", projected_total: "750.0",
                     range: { low: "450.0", high: "1050.0" } }, json.except(:usual_total))
      assert_in_delta 1_820 / 3r, BigDecimal(json[:usual_total]), 1e-9 # (600 + 610 + 610) / 3
    end
  end

  private
    def forecast_for_today(**options)
      IncomeStatement::SpendingForecast.new(IncomeStatement.new(@family), **options)
    end

    def money(amount)
      Money.new(amount, @family.currency)
    end

    def spend(category, amount, date)
      create_transaction(account: @account, category: category, amount: amount, date: date, name: "Spend #{date}")
    end

    # Food: 300 a month, 100 so far. Housing: 1,000 rent paid every month and
    # nothing else. Insurance: 500 due on the 25th, never paid before.
    # Uncategorized: 40 so far.
    def seed_month_with_bills
      rent = create_bill(category: @housing, amount: 1_000, name: "Rent", day: 3, account: @account)
      insurance = create_bill(category: @insurance, amount: 500, name: "Insurance", day: 25, account: @account)

      [ 6, 7, 8 ].each do |month|
        spend(@food, 300, Date.new(2026, month, 15))
        pay_bill(rent, date: Date.new(2026, month, 3))
      end
      spend(@food, 100, Date.new(2026, 9, 4))
      pay_bill(rent, date: Date.new(2026, 9, 3))
      spend(nil, 40, Date.new(2026, 9, 5))
      expect_bill(insurance, due_on: Date.new(2026, 9, 25))
    end

    # Every day of June to August costs 10, and the first ten days of each of
    # those months 40; the first ten days of September cost 25.
    def seed_daily_spending
      Date.new(2026, 6, 1).upto(Date.new(2026, 8, 31)) { |day| spend(@food, day.day <= 10 ? 40 : 10, day) }
      Date.new(2026, 9, 1).upto(Date.new(2026, 9, 10)) { |day| spend(@food, 25, day) }
    end
end
