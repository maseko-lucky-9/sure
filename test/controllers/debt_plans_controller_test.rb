require "test_helper"

class DebtPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = enable_preview(users(:family_admin))
    sign_in @admin
    ensure_tailwind_build
  end

  def enable_preview(user, enabled: true)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => enabled))
    user
  end

  def summary_text(label)
    assert_select "[data-testid=debt-plan-summary] h4", text: label
    css_select("[data-testid=debt-plan-summary] h4").find { |h4| h4.text.strip == label }.parent.at_css("p").text.squish
  end

  test "redirects users without preview access" do
    enable_preview(@admin, enabled: false)

    get debt_plan_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders the debts, the comparison and what was left out" do
    get debt_plan_url

    assert_response :success
    assert_select "[data-testid=debt-plan-debts]" do
      assert_select "td", text: "Credit Card"
      assert_select "td", text: "Mortgage Loan"
      assert_select "td", text: "$1,000.00"
      assert_select "td", text: "18.99%"
    end
    assert_select "[data-testid=debt-plan-left-out] li", text: /IOU \(personal debt to friend\)/
    assert_select "[data-testid=debt-plan-comparison] tbody tr", count: 2
    assert_select "[data-testid=debt-plan-summary]"
    assert_select "[data-testid=payoff-order] li", count: 2
    assert_select "select#strategy option[selected][value=avalanche]"
  end

  test "lists every month of the plan, ending with nothing remaining" do
    get debt_plan_url(extra: "1234.5")

    assert_response :success
    assert_select "input#extra[value=?]", "1234.50"
    months = css_select("[data-testid=debt-plan-summary] h4").find { |h4| h4.text.strip == "Months to go" }.parent.at_css("p").text[/\d+/].to_i
    rows = css_select("[data-testid=debt-plan-schedule] tbody tr")
    assert_equal months, rows.size
    assert_equal "$0.00", rows.last.css("td").last.text.squish
    assert_not_equal "$0.00", rows.first.css("td").last.text.squish
  end

  # The card (2%) has the smaller balance but the lower rate; the mortgage
  # (3.5%) is the avalanche target. Extra money therefore goes to different
  # debts, and the strategy changes what the plan costs.
  test "strategy param selects the plan and marks the compared row" do
    accounts(:credit_card).accountable.update_columns(apr: 2)

    get debt_plan_url(strategy: "avalanche", extra: "1000")
    avalanche_interest = summary_text("Total interest")
    assert_select "select#strategy option[selected][value=avalanche]"
    assert_select "[data-testid=debt-plan-comparison] tr.bg-container-inset", text: /Avalanche.*selected/m

    get debt_plan_url(strategy: "snowball", extra: "1000")
    snowball_interest = summary_text("Total interest")
    assert_select "select#strategy option[selected][value=snowball]"
    assert_select "[data-testid=debt-plan-comparison] tr.bg-container-inset", text: /Snowball.*selected/m

    assert_not_equal avalanche_interest, snowball_interest
    rows = css_select("[data-testid=debt-plan-comparison] tbody tr").to_h do |row|
      cells = row.css("td").map { |cell| cell.text.squish }
      [ cells.first[/\A\w+/], cells[2] ]
    end
    assert_equal({ "Avalanche" => avalanche_interest, "Snowball" => snowball_interest }, rows)
  end

  test "an unknown strategy falls back to avalanche" do
    get debt_plan_url(strategy: "yolo")

    assert_response :success
    assert_select "select#strategy option[selected][value=avalanche]"
  end

  test "the extra amount shortens the plan" do
    get debt_plan_url
    without_extra = summary_text("Total interest")

    get debt_plan_url(extra: "500")

    assert_response :success
    assert_select "input#extra[value=?]", "500.00"
    assert_not_equal without_extra, summary_text("Total interest")
  end

  test "a garbage or negative extra amount counts as zero" do
    get debt_plan_url
    baseline = summary_text("Total interest")

    [ "abc", "-50", "Infinity", "NaN", "1e9999", "" ].each do |extra|
      get debt_plan_url(extra: extra)

      assert_response :success, "extra=#{extra.inspect}"
      assert_equal baseline, summary_text("Total interest"), "extra=#{extra.inspect}"
      assert_select "input#extra[value]", count: 0
    end
  end

  test "a plan that cannot converge shows a message instead of failing" do
    member = enable_preview(users(:family_member))
    sign_in member
    accounts(:credit_card).accountable.update_columns(minimum_payment: 0.01)

    get debt_plan_url

    assert_response :success
    assert_select "[role=status]", text: /never pays off/
    assert_select "[data-testid=debt-plan-summary]", count: 0
    assert_select "[data-testid=debt-plan-schedule]", count: 0
    assert_select "[data-testid=debt-plan-comparison] td", text: "Does not finish", count: 2
    assert_select "[data-testid=debt-plan-debts] td", text: "Credit Card"
  end

  # accounts(:loan) belongs to the admin and is not shared; the card is.
  test "a member only sees the liabilities shared with them" do
    member = enable_preview(users(:family_member))
    sign_in member

    get debt_plan_url

    assert_response :success
    assert_select "[data-testid=debt-plan-debts] td", text: "Credit Card"
    assert_select "[data-testid=debt-plan-debts] td", text: "Mortgage Loan", count: 0
    assert_select "[data-testid=debt-plan-left-out]", count: 0
    assert_select "td", text: "Mortgage Loan", count: 0
    assert_no_match(/IOU \(personal debt/, response.body)
  end

  # Bank sync writes a card's APR through unchecked, so a bad value must not
  # take the page down.
  test "a card with a negative APR is left out rather than failing the page" do
    member = enable_preview(users(:family_member))
    sign_in member
    accounts(:credit_card).accountable.update_columns(apr: -1)

    get debt_plan_url

    assert_response :success
    assert_select "[data-testid=debt-plan-left-out]", text: /Credit Card/
    assert_select "[data-testid=debt-plan-debts]", count: 0
  end

  test "shows an empty state when there are no debts" do
    member = enable_preview(users(:family_member))
    AccountShare.where(user: member).destroy_all
    sign_in member

    get debt_plan_url

    assert_response :success
    assert_select "[data-testid=debt-plan-debts]", count: 0
    assert_select "p", text: "No debts to plan yet"
  end
end
