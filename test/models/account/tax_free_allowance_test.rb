require "test_helper"

class Account::TaxFreeAllowanceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # 2027 year of assessment: 1 March 2026 to 28 February 2027, limit R46,000.
  AS_OF = Date.new(2026, 6, 15)

  setup do
    @owner = users(:family_admin)
    @tfsa = create_tfsa(name: "TFSA one")
  end

  # --- nil cases

  test "is nil for an account that is not tax-free" do
    assert_nil Account::TaxFreeAllowance.for(accounts(:investment), as_of: AS_OF)
    assert_nil Account::TaxFreeAllowance.for(accounts(:depository), as_of: AS_OF)
  end

  test "is nil for the Canadian TFSA" do
    canadian = create_tfsa(name: "Canadian", subtype: "tfsa")

    assert_nil Account::TaxFreeAllowance.for(canadian, as_of: AS_OF)
  end

  test "is nil for a non-ZAR account" do
    usd = create_tfsa(name: "USD", currency: "USD")

    assert_nil Account::TaxFreeAllowance.for(usd, as_of: AS_OF)
  end

  test "is nil for an account with no owner" do
    @tfsa.update_columns(owner_id: nil)

    assert_nil Account::TaxFreeAllowance.for(@tfsa.reload, as_of: AS_OF)
  end

  test "is nil before the scheme began" do
    assert_nil Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2015, 2, 28))
  end

  test "is nil for an account being deleted" do
    @tfsa.update_columns(status: "pending_deletion")

    assert_nil Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)
  end

  # --- year of assessment

  test "a deposit on the last day of February counts in the old year and 1 March in the new" do
    deposit(@tfsa, 1_000, Date.new(2026, 2, 28))
    deposit(@tfsa, 2_000, Date.new(2026, 3, 1))

    old_year = Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2026, 2, 28))
    new_year = Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2026, 3, 1))

    assert_equal 2026, old_year.year_of_assessment
    assert_equal Date.new(2025, 3, 1), old_year.year_start
    assert_equal Date.new(2026, 2, 28), old_year.year_end
    assert_equal 1_000, old_year.contributed.amount

    assert_equal 2027, new_year.year_of_assessment
    assert_equal Date.new(2026, 3, 1), new_year.year_start
    assert_equal Date.new(2027, 2, 28), new_year.year_end
    assert_equal 2_000, new_year.contributed.amount
    assert_equal 3_000, new_year.lifetime_contributed.amount
  end

  test "a leap year ends on 29 February" do
    deposit(@tfsa, 1_000, Date.new(2028, 2, 29))
    deposit(@tfsa, 5_000, Date.new(2028, 3, 1))

    leap = Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2028, 2, 29))
    after = Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2028, 3, 1))

    assert_equal 2028, leap.year_of_assessment
    assert_equal Date.new(2027, 3, 1), leap.year_start
    assert_equal Date.new(2028, 2, 29), leap.year_end
    assert_equal 1_000, leap.contributed.amount
    assert_equal 2029, after.year_of_assessment
    assert_equal 5_000, after.contributed.amount
  end

  test "as_of defaults to today" do
    deposit(@tfsa, 7_000, Date.new(2026, 6, 1))

    travel_to Date.new(2026, 6, 15) do
      assert_equal 7_000, Account::TaxFreeAllowance.for(@tfsa).contributed.amount
    end
  end

  test "deposits after as_of count toward neither the year nor the lifetime figure" do
    deposit(@tfsa, 1_000, Date.new(2026, 6, 15))
    deposit(@tfsa, 9_000, Date.new(2026, 6, 16))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 1_000, allowance.contributed.amount
    assert_equal 1_000, allowance.lifetime_contributed.amount
  end

  # 490,000 deposited in earlier years and 4,000 this year: the annual limit
  # leaves 42,000 but the lifetime limit only 6,000.
  test "what is left is the smaller of the annual and lifetime room" do
    deposit(@tfsa, 490_000, Date.new(2020, 6, 1))
    deposit(@tfsa, 4_000, Date.new(2026, 4, 1))

    assert_equal 6_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).remaining.amount

    deposit(@tfsa, 10_000, Date.new(2026, 4, 2))

    assert_equal 0, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).remaining.amount
  end

  # --- limits

  test "the annual limit follows the year of assessment" do
    {
      Date.new(2016, 3, 1) => [ 2017, 30_000 ],
      Date.new(2017, 6, 1) => [ 2018, 33_000 ],
      Date.new(2018, 2, 28) => [ 2018, 33_000 ],
      Date.new(2020, 6, 1) => [ 2021, 36_000 ],
      Date.new(2026, 2, 28) => [ 2026, 36_000 ],
      Date.new(2026, 3, 1) => [ 2027, 46_000 ],
      Date.new(2031, 6, 1) => [ 2032, 46_000 ]
    }.each do |as_of, (year, limit)|
      allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: as_of)

      assert_equal year, allowance.year_of_assessment, "year for #{as_of}"
      assert_equal limit, allowance.annual_limit.amount, "limit for #{as_of}"
      assert_equal "ZAR", allowance.annual_limit.currency.iso_code
    end
  end

  test "the limit table starts with the first year of the scheme and is frozen" do
    assert Account::TaxFreeAllowance::ANNUAL_LIMITS.frozen?
    assert_equal 2016, Account::TaxFreeAllowance::ANNUAL_LIMITS.keys.min
    assert_equal 500_000, Account::TaxFreeAllowance::LIFETIME_LIMIT
  end

  test "year of assessment 2016 starts on 1 March 2015" do
    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: Date.new(2015, 3, 1))

    assert_equal 2016, allowance.year_of_assessment
    assert_equal 30_000, allowance.annual_limit.amount
  end

  # --- who is summed

  test "sums every tax-free account of the same owner and ignores another owner's" do
    second = create_tfsa(name: "TFSA two")
    other_owner = create_tfsa(name: "Someone else's", owner: users(:family_member))
    # Shared with the owner, so only the owner filter keeps it out of the sum.
    share(other_owner, @owner)
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))
    deposit(second, 5_000, Date.new(2026, 4, 2))
    deposit(other_owner, 20_000, Date.new(2026, 4, 3))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 15_000, allowance.contributed.amount
    assert_equal 2, allowance.account_count
    assert_equal 1, Account::TaxFreeAllowance.for(other_owner, as_of: AS_OF).account_count
  end

  test "a disabled account still counts and an account being deleted does not" do
    disabled = create_tfsa(name: "Disabled", status: "disabled")
    deleting = create_tfsa(name: "Deleting", status: "pending_deletion")
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    deposit(disabled, 2_000, Date.new(2026, 4, 1))
    deposit(deleting, 4_000, Date.new(2026, 4, 1))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 3_000, allowance.contributed.amount
    assert_equal 2, allowance.account_count
  end

  test "ignores the owner's accounts that are not ZAR tax-free investments" do
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    deposit(create_tfsa(name: "Canadian", subtype: "tfsa"), 2_000, Date.new(2026, 4, 1))
    deposit(accounts(:investment), 4_000, Date.new(2026, 4, 1))

    assert_equal 1_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  # --- what counts as a contribution

  test "withdrawals never restore room" do
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))
    withdraw(@tfsa, 10_000, Date.new(2026, 5, 1))
    deposit(@tfsa, 10_000, Date.new(2026, 6, 1))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 20_000, allowance.contributed.amount
    assert_equal 20_000, allowance.lifetime_contributed.amount
  end

  test "ignores excluded and pending transactions" do
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    deposit(@tfsa, 2_000, Date.new(2026, 4, 2), excluded: true)
    deposit(@tfsa, 4_000, Date.new(2026, 4, 3), extra: { "plaid" => { "pending" => true } })

    assert_equal 1_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "ignores returns and internal movements but counts unlabelled and Contribution deposits" do
    %w[Dividend Interest Reinvestment Sell Sweep\ In Sweep\ Out Exchange].each_with_index do |label, i|
      deposit(@tfsa, 100_000, Date.new(2026, 4, 1) + i, label: label)
    end
    deposit(@tfsa, 1_000, Date.new(2026, 4, 20))
    deposit(@tfsa, 2_000, Date.new(2026, 4, 21), label: "Contribution")
    deposit(@tfsa, 4_000, Date.new(2026, 4, 22), label: "Transfer")

    assert_equal 7_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "ignores trades and valuations" do
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    @tfsa.entries.create!(
      name: "Sell", date: Date.new(2026, 4, 2), amount: -9_000, currency: "ZAR",
      entryable: Trade.new(security: securities(:msft), qty: -3, price: 3_000, currency: "ZAR", investment_activity_label: "Sell")
    )
    @tfsa.entries.create!(
      name: "Valuation", date: Date.new(2026, 4, 3), amount: -8_000, currency: "ZAR",
      entryable: Valuation.new(kind: "reconciliation")
    )

    assert_equal 1_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "ignores an entry in another currency" do
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    deposit(@tfsa, 9_000, Date.new(2026, 4, 2), currency: "USD")

    assert_equal 1_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "a transfer from a bank account counts" do
    bank = create_bank_account
    create_transfer(from_account: bank, to_account: @tfsa, amount: 6_000, date: Date.new(2026, 4, 1), currency: "ZAR")

    assert_equal 6_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "a transfer between the owner's two tax-free accounts does not count" do
    second = create_tfsa(name: "TFSA two")
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))
    create_transfer(from_account: @tfsa, to_account: second, amount: 10_000, date: Date.new(2026, 4, 2), currency: "ZAR")

    allowance = Account::TaxFreeAllowance.for(second, as_of: AS_OF)

    assert_equal 10_000, allowance.contributed.amount
    assert_equal 10_000, allowance.lifetime_contributed.amount
  end

  # A suggested match the owner has not confirmed is only a guess: a withdrawal
  # from one account and a later deposit into another is a new contribution.
  test "an unconfirmed transfer match between the owner's accounts still counts" do
    second = create_tfsa(name: "TFSA two")
    transfer = create_transfer(from_account: @tfsa, to_account: second, amount: 10_000, date: Date.new(2026, 4, 2), currency: "ZAR")
    transfer.update_columns(status: "pending")

    assert_equal 10_000, Account::TaxFreeAllowance.for(second, as_of: AS_OF).contributed.amount
  end

  test "a fee rebate is not a deposit" do
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    deposit(@tfsa, 50, Date.new(2026, 4, 2), label: "Fee")

    assert_equal 1_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  test "a transfer in from another owner's tax-free account counts" do
    other_owner = create_tfsa(name: "Someone else's", owner: users(:family_member))
    create_transfer(from_account: other_owner, to_account: @tfsa, amount: 3_000, date: Date.new(2026, 4, 1), currency: "ZAR")

    assert_equal 3_000, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).contributed.amount
  end

  # --- lifetime

  test "lifetime sums every year since 1 March 2015" do
    deposit(@tfsa, 500, Date.new(2015, 2, 28))
    deposit(@tfsa, 1_000, Date.new(2015, 3, 1))
    deposit(@tfsa, 2_000, Date.new(2020, 6, 1))
    deposit(@tfsa, 4_000, Date.new(2026, 6, 1))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 7_000, allowance.lifetime_contributed.amount
    assert_equal 4_000, allowance.contributed.amount
    assert_equal 500_000, allowance.lifetime_limit.amount
  end

  # --- remaining, over_by, status

  test "remaining and over_by never go negative" do
    deposit(@tfsa, 10_000, Date.new(2026, 4, 1))
    within = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 36_000, within.remaining.amount
    assert_equal 0, within.over_by.amount

    deposit(@tfsa, 40_000, Date.new(2026, 4, 2))
    over = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_equal 0, over.remaining.amount
    assert_equal 4_000, over.over_by.amount
  end

  test "status follows the annual limit at 90 percent, at the limit and one cent over" do
    {
      "0" => :ok,
      "41399.99" => :ok,
      "41400" => :near,
      "46000" => :near,
      "46000.01" => :over
    }.each do |amount, status|
      @tfsa.entries.destroy_all
      deposit(@tfsa, BigDecimal(amount), Date.new(2026, 4, 1)) unless amount == "0"

      assert_equal status, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).status, "status for #{amount}"
    end
  end

  test "status follows the lifetime limit when the year is within its own" do
    {
      "449999.99" => :ok,
      "450000" => :near,
      "500000" => :near,
      "500000.01" => :over
    }.each do |amount, status|
      @tfsa.entries.destroy_all
      deposit(@tfsa, BigDecimal(amount), Date.new(2017, 6, 1))
      allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

      assert_equal 0, allowance.contributed.amount
      assert_equal status, allowance.status, "lifetime status for #{amount}"
    end
  end

  # --- visibility

  test "is nil when a member can open the viewed account but not another summed account" do
    second = create_tfsa(name: "TFSA two")
    deposit(@tfsa, 1_000, Date.new(2026, 4, 1))
    share(@tfsa, users(:family_member))

    assert_nil Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    share(second, users(:family_member))

    assert_equal 2, Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF).account_count
  end

  test "is present for an owner-only private set even though a member exists" do
    second = create_tfsa(name: "TFSA two")
    share(second, users(:family_member))

    allowance = Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)

    assert_not_nil allowance
    assert_equal 2, allowance.account_count
  end

  test "is present when the only member who cannot open another summed account is inactive" do
    create_tfsa(name: "TFSA two")
    share(@tfsa, users(:family_member))
    users(:family_member).update_columns(active: false)

    assert_not_nil Account::TaxFreeAllowance.for(@tfsa, as_of: AS_OF)
  end

  private
    def create_tfsa(name:, owner: @owner, currency: "ZAR", subtype: "tfsa_za", status: "active")
      owner.family.accounts.create!(
        name: name, owner: owner, balance: 0, currency: currency, status: status,
        accountable: Investment.new(subtype: subtype)
      )
    end

    def create_bank_account
      @owner.family.accounts.create!(
        name: "ZAR bank", owner: @owner, balance: 100_000, currency: "ZAR", accountable: Depository.new
      )
    end

    def deposit(account, amount, date, label: nil, excluded: false, extra: {}, currency: "ZAR")
      account.entries.create!(
        name: "Deposit", date: date, amount: -amount, currency: currency, excluded: excluded,
        entryable: Transaction.new(investment_activity_label: label, extra: extra)
      )
    end

    def withdraw(account, amount, date)
      account.entries.create!(
        name: "Withdrawal", date: date, amount: amount, currency: "ZAR",
        entryable: Transaction.new(investment_activity_label: "Withdrawal")
      )
    end

    def share(account, user)
      AccountShare.create!(account: account, user: user, permission: "read_only")
    end
end
