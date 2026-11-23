require "test_helper"

# The spending forecast counts bills still due, so the cached report has to
# notice when a bill changes without any transaction changing.
class ReportsForecastCacheTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  TODAY = Date.new(2026, 9, 15)
  UPDATING = /#{I18n.t("reports.index.updating")}/

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family.entries.where(entryable_type: "Transaction").destroy_all
    travel_to TODAY
    # Fixture rows are stamped with the real clock, which is after TODAY.
    @family.recurring_transactions.update_all(updated_at: TODAY - 1.day)
    @family.recurring_occurrences.update_all(updated_at: TODAY - 1.day)
    create_transaction(date: Date.new(2026, 9, 5), amount: 100, category: categories(:food_and_drink))
    # The month's first visit creates its budget rows, which moves the report's
    # version by itself. Get that out of the way before the cache is on.
    get reports_path
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "a bill added since the last build marks the report stale and queues a rebuild" do
    get reports_path
    assert_forecast(/On pace to spend \$?200\b/) # 100 in 15 days of 30

    travel Setting.page_cache_cooldown + 1.minute
    bill = create_bill(category: categories(:food_and_drink), amount: 400, name: "Water", day: 25)
    expect_bill(bill, due_on: Date.new(2026, 9, 25))

    assert_enqueued_jobs(1, only: RebuildReportJob) { get reports_path }
    assert_select "[data-testid=report-built-at]", text: UPDATING

    get reports_path(refresh: 1)
    follow_redirect!
    assert_forecast(/On pace to spend \$?600\b/) # the 400 still due counts once
  end

  test "skipping a bill's occurrence marks the report stale and queues a rebuild" do
    bill = create_bill(category: categories(:food_and_drink), amount: 400, name: "Water", day: 25)
    occurrence = expect_bill(bill, due_on: Date.new(2026, 9, 25))
    get reports_path
    assert_forecast(/On pace to spend \$?600\b/)

    travel Setting.page_cache_cooldown + 1.minute
    occurrence.skip!

    assert_enqueued_jobs(1, only: RebuildReportJob) { get reports_path }
    assert_select "[data-testid=report-built-at]", text: UPDATING

    get reports_path(refresh: 1)
    follow_redirect!
    assert_forecast(/On pace to spend \$?200\b/)
  end

  # A payment recorded by hand touches neither the bill, its occurrence nor an entry.
  test "a part payment recorded against a bill marks the report stale and queues a rebuild" do
    bill = create_bill(category: categories(:food_and_drink), amount: 400, name: "Water", day: 25)
    occurrence = expect_bill(bill, due_on: Date.new(2026, 9, 25))
    get reports_path
    assert_forecast(/On pace to spend \$?600\b/)

    travel Setting.page_cache_cooldown + 1.minute
    assert_no_changes -> { [ occurrence.reload.updated_at, bill.reload.updated_at, @family.entries.count ] } do
      RecurringTransaction::Allocator.new(occurrence).allocate!(amount: 150)
    end

    assert_enqueued_jobs(1, only: RebuildReportJob) { get reports_path }
    assert_select "[data-testid=report-built-at]", text: UPDATING

    get reports_path(refresh: 1)
    follow_redirect!
    assert_forecast(/On pace to spend \$?450\b/) # 250 of the bill is still due
  end

  test "a payment corrected within the same second still marks the report stale" do
    bill = create_bill(category: categories(:food_and_drink), amount: 400, name: "Water", day: 25)
    occurrence = expect_bill(bill, due_on: Date.new(2026, 9, 25))
    travel_to TODAY.to_time(:utc) + 10.hours + 0.1.seconds, with_usec: true
    payment = RecurringTransaction::Allocator.new(occurrence).allocate!(amount: 150)
    get reports_path

    travel_to TODAY.to_time(:utc) + 10.hours + 0.6.seconds, with_usec: true
    payment.update!(allocated_amount: 100)

    get reports_path
    assert_select "[data-testid=report-built-at]", text: UPDATING
  end

  test "moving a bill to another category marks the report stale and queues a rebuild" do
    bill = create_bill(category: categories(:food_and_drink), amount: 400, name: "Water", day: 25)
    expect_bill(bill, due_on: Date.new(2026, 9, 25))
    get reports_path

    travel Setting.page_cache_cooldown + 1.minute
    bill.update!(category: categories(:income))

    assert_enqueued_jobs(1, only: RebuildReportJob) { get reports_path }
    assert_select "[data-testid=report-built-at]", text: UPDATING
  end

  test "an unchanged report is served as current" do
    get reports_path
    travel Setting.page_cache_cooldown + 1.minute

    assert_no_enqueued_jobs(only: RebuildReportJob) { get reports_path }
    assert_select "[data-testid=report-built-at]", text: UPDATING, count: 0
  end

  private
    def assert_forecast(pattern)
      assert_response :ok
      assert_select "[data-testid='spending-forecast']", text: pattern
    end
end
