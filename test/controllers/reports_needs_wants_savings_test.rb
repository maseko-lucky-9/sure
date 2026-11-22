require "test_helper"

class ReportsNeedsWantsSavingsTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  SECTION = "section[data-section-key='needs_wants_savings']"
  AUGUST = { period_type: "custom", start_date: "2026-08-01", end_date: "2026-08-31" }.freeze

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.entries.where(entryable_type: "Transaction").destroy_all
  end

  test "shows each group's amount, share of income and distance from the 50/30/20 target" do
    preview(true)
    pet_shop = @family.categories.create!(name: "Pet shop", color: "#123456", lucide_icon: "paw-print")
    create_transaction(date: Date.new(2026, 8, 3), amount: -3000, category: categories(:income))
    create_transaction(date: Date.new(2026, 8, 5), amount: 600, category: categories(:food_and_drink))
    create_transaction(date: Date.new(2026, 8, 6), amount: 100, category: pet_shop)

    travel_to(Date.new(2026, 9, 15)) { get reports_path(AUGUST) }

    assert_response :ok
    assert_select SECTION do
      assert_select "[data-testid='nws-needs']", text: /Needs/
      assert_select "[data-testid='nws-needs']", text: /\$0\b/
      assert_select "[data-testid='nws-needs']", text: /-\$1,500 under/

      assert_select "[data-testid='nws-wants']", text: /\$600\b.*20\.0% of income/m
      assert_select "[data-testid='nws-wants']", text: /-\$300 under/

      assert_select "[data-testid='nws-savings']", text: /\$2,300\b.*76\.7% of income/m
      assert_select "[data-testid='nws-savings']", text: /\+\$1,700 over/

      assert_select "[data-testid='nws-unassigned']", text: /\$100\b.*3\.3% of income.*Pet shop/m
      assert_select "[data-testid='nws-unassigned'] a[href=?]", categories_path
      assert_select "[data-testid='nws-savings-note']", text: /left unspent/
      assert_select "[data-testid='nws-in-progress']", count: 0
    end
  end

  test "says that an unfinished period counts money not yet spent as savings" do
    preview(true)
    create_transaction(date: Date.new(2026, 9, 3), amount: -3000, category: categories(:income))

    travel_to(Date.new(2026, 9, 15)) do
      get reports_path(period_type: "custom", start_date: "2026-09-01", end_date: "2026-09-30")
    end

    assert_select "#{SECTION} [data-testid='nws-in-progress']", text: /not over/
  end

  test "has no unassigned row when every group is assigned" do
    preview(true)
    create_transaction(date: Date.new(2026, 8, 3), amount: -3000, category: categories(:income))
    create_transaction(date: Date.new(2026, 8, 5), amount: 600, category: categories(:food_and_drink))

    travel_to(Date.new(2026, 9, 15)) { get reports_path(AUGUST) }

    assert_select SECTION
    assert_select "[data-testid='nws-unassigned']", count: 0
  end

  test "names the largest few unassigned categories and counts the rest" do
    preview(true)
    create_transaction(date: Date.new(2026, 8, 3), amount: -3000, category: categories(:income))
    { "Alpha" => 50, "Bravo" => 40, "Charlie" => 30, "Delta" => 20, "Echo" => 10 }.each do |name, amount|
      category = @family.categories.create!(name: name, color: "#123456", lucide_icon: "shapes")
      create_transaction(date: Date.new(2026, 8, 5), amount: amount, category: category)
    end

    travel_to(Date.new(2026, 9, 15)) { get reports_path(AUGUST) }

    assert_select "[data-testid='nws-unassigned']", text: /\$150\b.*Alpha, Bravo, Charlie and 2 more/m
  end

  test "is a preview section" do
    preview(false)
    create_transaction(date: Date.new(2026, 8, 3), amount: -3000, category: categories(:income))

    travel_to(Date.new(2026, 9, 15)) { get reports_path(AUGUST) }

    assert_response :ok
    assert_select SECTION, count: 0
  end

  test "shows a short note instead of the table when the period has no income" do
    preview(true)
    create_transaction(date: Date.new(2026, 8, 5), amount: 600, category: categories(:food_and_drink))

    travel_to(Date.new(2026, 9, 15)) { get reports_path(AUGUST) }

    assert_select SECTION do
      assert_select "[data-testid='nws-no-income']", text: /no income/
      assert_select "table", count: 0
    end
  end

  private
    def preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end
