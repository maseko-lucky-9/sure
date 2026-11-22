require "test_helper"

class Insight::Generators::SavingsOpportunityGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # "Today" is Nov 20 2026, so the last two finished months are October (31
  # days) and September (30 days) 2026.
  #
  # A category's normal is its spending over the 365 days before the month,
  # scaled to the month's length. `usual` books 365 x N on one day, so:
  #   September's normal is 30 x N;
  #   October's normal is 31 x N, plus 31/365 of whatever September spent,
  #   because September is part of October's year. Tests spend multiples of
  #   365 in September to keep that whole: 730 adds 62, 7,300 adds 620.
  #
  # With N = 10 / 20 / 200 a day: Dining out, Transport, Fun and Gifts are
  # normally 300 then 310, Groceries 600 then 620, Housing 6,000 then 6,200.
  # October's normal_total is 8,060 plus those September additions.
  MONTH = Date.new(2026, 10, 20)   # a day inside last month
  EARLIER = Date.new(2026, 9, 20)  # a day inside the month before
  BASELINE_DAY = Date.new(2025, 12, 1)

  setup do
    travel_to Date.new(2026, 11, 20)
    @family = families(:dylan_family)
    # `depository` is shared with every member; `connected` is private to the admin.
    @private = accounts(:connected)

    # The fixtures' entries are dated relative to the real clock; start clean.
    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").delete_all

    @dining = category("Dining out")
    @transport = category("Transport")
    @groceries = category("Groceries")
    @fun = category("Fun")
    @gifts = category("Gifts")
    @housing = category("Housing")

    # Earlier than any baseline starts, so history reaches back the whole year
    # (a custom month start of the 15th included) without adding to a total.
    create_transaction(amount: 1, date: Date.new(2025, 9, 1), name: "history anchor")
    { @dining => 10, @transport => 10, @groceries => 20, @fun => 10, @gifts => 10, @housing => 200 }.each do |category, per_day|
      usual(category, per_day)
    end
  end

  teardown { travel_back }

  # Dining out: September 730 on a normal of 300 (+430); October 822 on 372
  # (+450); the smaller, 430, is claimed. Transport: +430 then 672 on 372
  # (+300); 300 is claimed. Saving 730, 8.9% of 8,184.
  test "names the categories above normal two months running and the smaller overage of each" do
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 822)
    spend(@transport, 730, date: EARLIER)
    spend(@transport, 672)

    insight = generate.sole

    assert_equal "savings_opportunity", insight.insight_type
    assert_equal "savings_opportunity", insight.template_key
    assert_equal "You could save $730.00 a month", insight.title
    assert_equal({ saving: "$730.00", count: 2, categories: "Dining out ($430.00) and Transport ($300.00)" }, insight.facts)
    assert_equal Date.new(2026, 10, 1), insight.period_start
    assert_equal Date.new(2026, 10, 31), insight.period_end
    assert_equal "savings_opportunity:2026-10", insight.dedup_key
    assert_equal 5, insight.metadata[:saving_bucket] # 8.9% falls in the 5-9% bucket
    assert insight.metadata[:accounts_digest].present?
    assert_equal "USD", insight.currency
  end

  test "writes the body and title from the facts in the family's locale" do
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 822)
    spend(@transport, 730, date: EARLIER)
    spend(@transport, 672)

    insight = I18n.with_locale(:es) { generate.sole }

    assert_includes insight.facts[:categories], " y "
    assert_equal "Podrías ahorrar #{insight.facts[:saving]} al mes", insight.title
    assert_includes I18n.with_locale(:es) { Insight::BodyWriter.new.write(insight) }, "dos meses seguidos"
  end

  test "stays quiet when spending matched normal" do
    { @dining => 310, @transport => 310, @groceries => 620, @fun => 310, @gifts => 310, @housing => 6_200 }.each do |category, amount|
      spend(category, amount)
    end

    assert_empty generate
  end

  # One appliance is not a monthly saving, however large.
  test "does not report a single month's spike" do
    spend(@housing, 26_200)

    assert_empty generate

    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").where(date: MONTH).delete_all
    spend(@housing, 26_000, date: EARLIER)

    assert_empty generate
  end

  # Housing: September 7,300 on 6,000 (+21.7%), making October's normal 6,820.
  # October at +681 is 9.99% above it; at +682 it is exactly 10%.
  test "ignores a category less than 10% above its normal" do
    spend(@housing, 7_300, date: EARLIER)
    spend(@housing, 7_501)

    assert_empty generate

    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").where(date: MONTH).delete_all
    spend(@housing, 7_502)

    assert_equal "$682.00", generate.sole.facts[:saving]
  end

  # Dining out: September +430, October normal 372. October's normal_total is
  # 8,122, so the floor is 406.1: a saving of 406 falls short, 407 clears it.
  test "needs a saving of at least 5% of normal spending" do
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 778) # +406

    assert_empty generate

    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").where(date: MONTH).delete_all
    spend(@dining, 779) # +407

    assert_equal "$407.00", generate.sole.facts[:saving]
  end

  # Four months of history: both months compare (September against 92 days,
  # October against 122) and Dining out is far above each, but that "normal"
  # is little more than the months themselves.
  test "does not suggest a saving from less than six months of history" do
    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").delete_all
    create_transaction(category: @dining, amount: 300, date: Date.new(2026, 6, 1), name: "first ever")
    spend(@dining, 900, date: EARLIER)
    spend(@dining, 900)

    assert_empty generate
  end

  # Dining out 430, Transport 300, Fun 200 (572 on 372) and Gifts 100 (472 on
  # 372) all qualify; the saving counts the top three only: 930, 11.2% of 8,308.
  test "names only the three furthest above normal and sums just those" do
    [ @dining, @transport, @fun, @gifts ].each { |category| spend(category, 730, date: EARLIER) }
    spend(@dining, 822)
    spend(@transport, 672)
    spend(@fun, 572)
    spend(@gifts, 472)

    insight = generate.sole

    assert_equal "$930.00", insight.facts[:saving]
    assert_equal 3, insight.facts[:count]
    assert_equal "Dining out ($430.00), Transport ($300.00), and Fun ($200.00)", insight.facts[:categories]
    assert_not_includes insight.facts[:categories], "Gifts"
    assert_equal 10, insight.metadata[:saving_bucket]
  end

  # Uncategorized spending is not a category the family can decide to cut.
  # Normally 6,000 then about 6,964; 9,000 and 12,000 spent, well past both.
  test "does not name uncategorized overspending" do
    usual(nil, 200)
    spend(nil, 9_000, date: EARLIER)
    spend(nil, 12_000)

    assert_empty generate
  end

  # The last finished months are September 15 to October 14 and October 15 to
  # November 14. The second spike is dated November 5, outside calendar
  # October, so it only counts under the custom month.
  test "reads the last two months of a custom month start day" do
    @family.update!(month_start_day: 15)
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 822, date: Date.new(2026, 11, 5))

    insight = generate.sole

    assert_equal Date.new(2026, 10, 15), insight.period_start
    assert_equal Date.new(2026, 11, 14), insight.period_end
    assert_equal "savings_opportunity:2026-10", insight.dedup_key
    assert_equal "$430.00", insight.facts[:saving]
  end

  test "does not count the calendar months of a family with a custom start day" do
    @family.update!(month_start_day: 15)
    spend(@dining, 730, date: Date.new(2026, 9, 5)) # before the 15th: three months back
    spend(@dining, 822, date: Date.new(2026, 10, 5)) # the month before last, not the last

    assert_empty generate
  end

  # The same spikes as the first test, booked on `connected`, which is private
  # to one member. The shared feed must not report a figure built from them.
  test "ignores spending on an account private to one member" do
    create_transaction(category: @dining, amount: 730, date: EARLIER, name: "private spike", account: @private)
    create_transaction(category: @dining, amount: 822, date: MONTH, name: "private spike", account: @private)

    assert_empty generate
  end

  test "builds the same dedup key and metadata when run twice" do
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 822)

    first = generate.sole
    second = generate.sole

    assert_equal first.dedup_key, second.dedup_key
    assert_equal first.metadata, second.metadata
  end

  # High priority sends a push notification, and a look back is never urgent.
  # Dining out +7,000 then +4,070 is 47% of normal spending.
  test "stays medium priority however large the saving" do
    spend(@dining, 7_300, date: EARLIER)
    spend(@dining, 5_000)

    insight = generate.sole

    assert_equal "$4,070.00", insight.facts[:saving]
    assert_equal "medium", insight.priority
  end

  # October ends on the 31st; its last transactions can still arrive for a few days.
  test "waits three days after the month ends" do
    spend(@dining, 730, date: EARLIER)
    spend(@dining, 900)

    travel_to Date.new(2026, 11, 2)
    assert_empty generate

    travel_to Date.new(2026, 11, 3)
    assert_equal 1, generate.size
  end

  test "is registered and its type is valid" do
    assert_includes Insight::GeneratorRegistry::GENERATORS, Insight::Generators::SavingsOpportunityGenerator
    assert_includes Insight::TYPES, "savings_opportunity"
  end

  private
    def generate
      Insight::Generators::SavingsOpportunityGenerator.new(@family).generate
    end

    def category(name)
      @family.categories.create!(name: name, color: "#101010", lucide_icon: "circle")
    end

    # A year of spending that makes `per_day` x 31 the category's normal month.
    def usual(category, per_day)
      create_transaction(category: category, amount: 365 * per_day, date: BASELINE_DAY, name: "usual #{category&.name}")
    end

    def spend(category, amount, date: MONTH)
      create_transaction(category: category, amount: amount, date: date, name: "spend #{category&.name}")
    end
end
