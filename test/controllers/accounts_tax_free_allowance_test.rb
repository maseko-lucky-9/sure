require "test_helper"

# The tax-free allowance alert on the account page. The family is set to ZAR so
# the page makes no exchange-rate lookup for a rand account.
class AccountsTaxFreeAllowanceTest < ActionDispatch::IntegrationTest
  ALERT = "[data-testid='tax-free-allowance']".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.family.update!(currency: "ZAR")
    @tfsa = create_tfsa("TFSA one")
    travel_to Date.new(2026, 6, 15)
  end

  teardown { travel_back }

  test "shows the allowance used and left for a tax-free account" do
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))

    get account_url(@tfsa)

    assert_response :success
    assert_select ALERT, count: 1
    assert_select "#{ALERT} [class*='bg-info/10']", count: 1
    text = alert_text
    assert_includes text, "Tax-free savings allowance"
    assert_includes text, "Deposits recorded in Sure this tax year come to #{rand_amount(10000)} of the #{rand_amount(46000)} limit, leaving #{rand_amount(36000)}."
    assert_includes text, "The tax year ends on February 28, 2027."
    assert_not_includes text, "across"
    assert_not_includes text, "lifetime"
    assert_select "#{ALERT}.privacy-sensitive"
  end

  test "warns when close to the limit" do
    deposit(@tfsa, 41_400, Date.new(2026, 4, 1))

    get account_url(@tfsa)

    assert_select "#{ALERT} [class*='bg-warning/10']", count: 1
  end

  test "says SARS taxes the excess when over the annual limit" do
    deposit(@tfsa, 50_000, Date.new(2026, 4, 1))

    get account_url(@tfsa)

    assert_select "#{ALERT} [class*='bg-destructive/10']", count: 1
    assert_includes alert_text, "Deposits recorded in Sure this tax year come to #{rand_amount(50000)}, over the #{rand_amount(46000)} limit. SARS taxes the #{rand_amount(4000)} over the limit at 40%."
  end

  test "names the number of accounts when the owner has several" do
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))
    deposit(create_tfsa("TFSA two"), 5_000, Date.new(2026, 4, 2))

    get account_url(@tfsa)

    assert_includes alert_text, "come to #{rand_amount(15000)} of the #{rand_amount(46000)} limit"
    assert_includes alert_text, "This figure is across 2 tax-free accounts."
  end

  test "adds the lifetime sentence only when lifetime is near or over" do
    deposit(@tfsa, 450_000, Date.new(2017, 6, 1))

    get account_url(@tfsa)

    assert_includes alert_text, "Over all years they come to #{rand_amount(450000)} of the #{rand_amount(500000)} lifetime limit."

    deposit(@tfsa, 60_000, Date.new(2018, 6, 1))

    get account_url(@tfsa)

    assert_includes alert_text, "Over all years they come to #{rand_amount(510000)}, over the #{rand_amount(500000)} lifetime limit. SARS taxes the excess at 40%."
  end

  test "does not show for an ordinary investment account" do
    brokerage = @user.family.accounts.create!(
      name: "Brokerage", owner: @user, balance: 0, currency: "ZAR", accountable: Investment.new(subtype: "brokerage")
    )
    deposit(brokerage, 10_000, Date.new(2026, 4, 1))

    get account_url(brokerage)

    assert_response :success
    assert_select ALERT, count: 0
  end

  test "does not show when another member could not open every summed account" do
    second = create_tfsa("TFSA two")
    AccountShare.create!(account: @tfsa, user: users(:family_member), permission: "read_only")

    get account_url(@tfsa)

    assert_response :success
    assert_select ALERT, count: 0

    AccountShare.create!(account: second, user: users(:family_member), permission: "read_only")

    get account_url(@tfsa)

    assert_select ALERT, count: 1
  end

  private
    def alert_text
      css_select(ALERT).first.text.squish
    end

    # Amounts as the app formats rand, so the test does not depend on a locale's separators.
    def rand_amount(amount)
      Money.new(amount, "ZAR").format.squish
    end

    def create_tfsa(name)
      @user.family.accounts.create!(
        name: name, owner: @user, balance: 0, currency: "ZAR", accountable: Investment.new(subtype: "tfsa_za")
      )
    end

    def deposit(account, amount, date)
      account.entries.create!(name: "Deposit", date: date, amount: -amount, currency: "ZAR", entryable: Transaction.new)
    end
end
