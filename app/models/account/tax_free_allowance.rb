# How much of a South African tax-free savings allowance a person has used.
#
# SARS limits what one PERSON may put into tax-free investments, summed across
# all their tax-free accounts: an annual limit for each year of assessment
# (1 March to the last day of February) and a lifetime limit. Anything over
# either limit is taxed at 40%.
#
#   Account::TaxFreeAllowance.for(account, as_of: Date.current)
#
# returns nil unless the account is a ZAR `tfsa_za` investment with an owner and
# the figure is safe to show every member who can open the account.
#
# Assumption: a transfer between two tax-free accounts of the same person is
# not a contribution, so it is left out of the sum.
class Account::TaxFreeAllowance
  SUBTYPE = "tfsa_za".freeze
  CURRENCY = "ZAR".freeze

  # Annual limit in rand, keyed by the first year of assessment it applies to.
  # A year takes the highest key not above it. Source: SARS "Tax free
  # investments" page, read 22 November 2026. The scheme began on 1 March 2015,
  # which is the start of the 2016 year of assessment; nothing applies before.
  ANNUAL_LIMITS = { 2016 => 30_000, 2018 => 33_000, 2021 => 36_000, 2027 => 46_000 }.freeze
  LIFETIME_LIMIT = 500_000
  SCHEME_START = Date.new(2015, 3, 1)

  # Percentage of a limit at which status turns :near. Compared as integers
  # (total * 100 >= limit * NEAR_PERCENT) so "exactly 90%" is exact.
  NEAR_PERCENT = 90

  # Deposit labels that are returns on the money or movements inside the
  # account, not new money: the internal movement labels (minus "Transfer",
  # which providers also use for a real deposit, handled by the transfer test
  # below), plus returns, sales and fee rebates.
  NOT_CONTRIBUTION_LABELS = (
    Transaction::INTERNAL_MOVEMENT_LABELS - [ "Transfer" ] + %w[Dividend Interest Reinvestment Sell Fee]
  ).uniq.freeze

  attr_reader :year_of_assessment, :year_start, :year_end, :account_count

  # Contribution definition. Across ALL of the owner's ZAR tfsa_za investment
  # accounts in the family (not only the one viewed), sums -entries.amount for
  # entries that:
  #   - are Transactions with a negative amount (a deposit; outflows are ignored,
  #     because a withdrawal never restores room and money withdrawn and put
  #     back is a new contribution),
  #   - are not excluded, not pending, and in ZAR (an entry in another currency
  #     is skipped, not converted),
  #   - dated from the start of the year (or 1 March 2015) up to as_of; a
  #     scheduled or future-dated deposit counts nothing until its day arrives,
  #   - carry no returns/internal label (NOT_CONTRIBUTION_LABELS; an unlabelled
  #     transaction counts),
  #   - are not the inflow leg of a confirmed Transfer whose outflow leg sits on
  #     another of the owner's tax-free accounts. A suggested match that was
  #     never confirmed still counts.
  # Accounts that are draft, active or disabled count; ones being deleted do
  # not (Account.historical). A split parent is excluded by Entry#split!, so
  # only its children count.
  #
  # Blind spots, so the figure can mislead:
  #   - An opening balance or valuation is not a deposit, so money contributed
  #     before it was tracked in Sure is missing. Lifetime is "recorded in
  #     Sure", a lower bound.
  #   - Interest imported as a plain unlabelled transaction counts as a deposit.
  #   - An untracked transfer from another provider's tax-free account counts as
  #     a deposit.
  #   - Every tax-free account under one owner is taken to be one person's. A
  #     child's account kept under a parent's login is added to the parent's.
  #   - The figure is hidden from everyone, the owner included, when someone the
  #     viewed account is shared with cannot open all the accounts summed.
  def self.for(account, as_of: Date.current)
    return nil unless eligible?(account) && as_of >= SCHEME_START

    accounts = owner_accounts(account).to_a
    return nil unless accounts.any? { |a| a.id == account.id }
    return nil unless visible_to_all_who_can_open?(account, accounts)

    year_total, lifetime_total = contributions(accounts.map(&:id), as_of)
    new(as_of: as_of, account_count: accounts.size, year_total: year_total, lifetime_total: lifetime_total)
  end

  def self.eligible?(account)
    account.accountable_type == "Investment" &&
      account.accountable.subtype == SUBTYPE &&
      account.currency == CURRENCY &&
      account.owner_id.present?
  end
  private_class_method :eligible?

  def self.owner_accounts(account)
    account.family.accounts.historical
      .joins("INNER JOIN investments ON investments.id = accounts.accountable_id AND accounts.accountable_type = 'Investment'")
      .where(owner_id: account.owner_id, currency: CURRENCY, investments: { subtype: SUBTYPE })
  end
  private_class_method :owner_accounts

  # The total sums accounts beyond the one on screen and the page is also
  # rendered by a broadcast with no Current.user, so it must be safe for every
  # active family member who can open the viewed account: each must be able to
  # open every summed account too. The owner opens all of their own accounts,
  # so only shares can differ.
  def self.visible_to_all_who_can_open?(viewed, accounts)
    allowed = Hash.new { |hash, id| hash[id] = Set.new }
    accounts.each { |a| allowed[a.id] << a.owner_id }
    AccountShare.where(account_id: accounts.map(&:id)).pluck(:account_id, :user_id).each { |id, user| allowed[id] << user }

    viewers = viewed.family.users.where(active: true, id: allowed[viewed.id].to_a).pluck(:id).to_set
    accounts.all? { |a| viewers.subset?(allowed[a.id]) }
  end
  private_class_method :visible_to_all_who_can_open?

  # [this year's total, lifetime total], both up to as_of, in one query.
  def self.contributions(account_ids, as_of)
    year_start = year_start_for(as_of)
    sql = Entry.sanitize_sql_array([ <<~SQL.squish, { ids: account_ids, scheme_start: SCHEME_START, year_start: year_start, as_of: as_of, currency: CURRENCY, labels: NOT_CONTRIBUTION_LABELS } ])
      SELECT
        COALESCE(SUM(-entries.amount) FILTER (WHERE entries.date >= :year_start), 0),
        COALESCE(SUM(-entries.amount), 0)
      FROM entries
      INNER JOIN transactions ON transactions.id = entries.entryable_id
      WHERE entries.entryable_type = 'Transaction'
        AND entries.account_id IN (:ids)
        AND entries.amount < 0
        AND entries.excluded = FALSE
        AND entries.currency = :currency
        AND entries.date BETWEEN :scheme_start AND :as_of
        AND #{Transaction.not_pending_sql("transactions")}
        AND (transactions.investment_activity_label IS NULL OR transactions.investment_activity_label NOT IN (:labels))
        AND NOT EXISTS (
          SELECT 1 FROM transfers
          INNER JOIN entries outflow_entries
            ON outflow_entries.entryable_type = 'Transaction'
           AND outflow_entries.entryable_id = transfers.outflow_transaction_id
          WHERE transfers.inflow_transaction_id = transactions.id
            AND transfers.status = 'confirmed'
            AND outflow_entries.account_id IN (:ids)
        )
    SQL

    Entry.connection.select_rows(sql).first.map { |value| BigDecimal(value.to_s) }
  end
  private_class_method :contributions

  # The year of assessment a date falls in is the calendar year its 1 March to
  # end of February span finishes in.
  def self.year_of(date)
    date.month >= 3 ? date.year + 1 : date.year
  end

  def self.year_start_for(date)
    Date.new(year_of(date) - 1, 3, 1)
  end

  def initialize(as_of:, account_count:, year_total:, lifetime_total:)
    @year_of_assessment = self.class.year_of(as_of)
    @year_start = Date.new(@year_of_assessment - 1, 3, 1)
    @year_end = Date.new(@year_of_assessment, 3, 1) - 1
    @account_count = account_count
    @annual_limit = ANNUAL_LIMITS.select { |first_year, _| first_year <= @year_of_assessment }.max_by(&:first).last
    @year_total = year_total
    @lifetime_total = lifetime_total
  end

  def annual_limit = money(@annual_limit)
  def contributed = money(@year_total)
  # Room under whichever limit is reached first.
  def remaining = money([ @annual_limit - @year_total, LIFETIME_LIMIT - @lifetime_total ].min.clamp(0, nil))
  def over_by = money([ @year_total - @annual_limit, 0 ].max)
  def lifetime_limit = money(LIFETIME_LIMIT)
  def lifetime_contributed = money(@lifetime_total)

  def status
    if @year_total > @annual_limit || @lifetime_total > LIFETIME_LIMIT
      :over
    elsif near?(@year_total, @annual_limit) || near?(@lifetime_total, LIFETIME_LIMIT)
      :near
    else
      :ok
    end
  end

  def lifetime_status
    if @lifetime_total > LIFETIME_LIMIT then :over
    elsif near?(@lifetime_total, LIFETIME_LIMIT) then :near
    else :ok
    end
  end

  private
    def near?(total, limit)
      total * 100 >= limit * NEAR_PERCENT
    end

    def money(amount)
      Money.new(amount, CURRENCY)
    end
end
