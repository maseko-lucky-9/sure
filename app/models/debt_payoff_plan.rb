# A month-by-month plan for clearing several debts at once, by the snowball
# (smallest balance first) or avalanche (highest APR first) method.
#
# Pure calculation: it reads nothing and writes nothing. All debts are in one
# currency; the caller decides which debts qualify (see .debts_for).
#
# Each month, in order:
#   1. every active debt accrues interest (balance * apr / 100 / 12);
#   2. every active debt receives its minimum payment, capped at what it owes;
#   3. a pool is formed from the extra monthly amount, the full minimums of
#      debts cleared in an EARLIER month (they keep being paid, rolled over to
#      the next target) and the part of a minimum a debt did not need because
#      it cleared this month;
#   4. the pool goes to the active debts in strategy order, re-sorted every
#      month, each taking at most what it still owes.
# Money is rounded to 0.01, half up, at every step.
class DebtPayoffPlan
  STRATEGIES = %i[avalanche snowball].freeze
  MAX_MONTHS = 600
  CENTS = 2
  ROUNDING = BigDecimal::ROUND_HALF_UP

  class NotConverging < StandardError; end

  Debt = Data.define(:name, :balance, :apr, :minimum_payment)

  DebtMonth = Data.define(:name, :starting_balance, :interest, :payment, :ending_balance)
  Month = Data.define(:number, :total_paid, :interest, :debts) do
    # What is still owed across all debts once this month's payments are made.
    def remaining
      debts.sum(BigDecimal("0"), &:ending_balance)
    end
  end

  # Debts that could be planned, and those that could not be and why.
  # Each left-out entry is a LeftOut: the account's name and a reason symbol
  # (:other_currency, :missing_apr, :missing_minimum, :unsupported_type).
  Loaded = Data.define(:debts, :left_out)
  LeftOut = Data.define(:name, :reason)

  attr_reader :strategy, :extra_monthly, :months, :total_interest, :total_paid, :payoff_order, :schedule

  class << self
    # Builds the plannable debts from a relation of accounts the caller may
    # access. Liabilities store their balance as a positive amount owed.
    # Accounts that are not owed anything are skipped: there is nothing to
    # plan. Everything else is either a Debt or listed in left_out. Nothing is
    # converted between currencies and no APR or minimum is ever guessed.
    def debts_for(accounts, currency: Current.family.primary_currency_code)
      debts = []
      left_out = []

      accounts.liabilities.visible.includes(:accountable).alphabetically.each do |account|
        next unless account.balance.positive?

        apr, minimum_payment = terms_for(account.accountable)

        reason =
          if apr == :unsupported
            :unsupported_type
          elsif account.currency != currency
            :other_currency
          elsif apr.nil? || apr.negative?
            :missing_apr
          elsif minimum_payment.nil? || !minimum_payment.positive?
            :missing_minimum
          end

        if reason
          left_out << LeftOut.new(name: account.name, reason: reason)
        else
          debts << Debt.new(name: account.name, balance: account.balance, apr: apr, minimum_payment: minimum_payment)
        end
      end

      Loaded.new(debts: debts, left_out: left_out)
    end

    private
      # [apr, minimum]; apr is :unsupported for a liability type with neither.
      def terms_for(accountable)
        case accountable
        when Loan
          [ accountable.interest_rate, accountable.monthly_payment&.amount ]
        when CreditCard
          [ accountable.apr, accountable.minimum_payment ]
        else
          [ :unsupported, nil ]
        end
      end
  end

  def initialize(debts:, extra_monthly: 0, strategy: :avalanche)
    @strategy = normalize_strategy(strategy)
    @extra_monthly = money!(extra_monthly, "extra_monthly")
    @debts = Array(debts).map { |debt| normalize_debt(debt) }.select { |debt| debt.balance.positive? }

    calculate
  end

  # The date the last debt is cleared, counting the plan's first payment as one
  # month from +from+. nil when there is nothing to pay off.
  def debt_free_on(from: Date.current)
    months.zero? ? nil : from.next_month(months)
  end

  private
    attr_reader :debts

    # Mutable per-debt state for the run; kept apart from the immutable Debt.
    State = Struct.new(:debt, :balance, :cleared_in, keyword_init: true) do
      def active? = balance.positive?
    end

    def calculate
      @months = 0
      @total_interest = BigDecimal("0")
      @total_paid = BigDecimal("0")
      @payoff_order = []
      @schedule = []
      return if debts.empty?

      raise_if_unpayable!

      states = debts.map { |debt| State.new(debt: debt, balance: debt.balance, cleared_in: nil) }

      (1..MAX_MONTHS).each do |number|
        run_month(number, states)
        break if states.none?(&:active?)
      end

      raise NotConverging, "debts are not cleared within #{MAX_MONTHS} months" if states.any?(&:active?)

      @months = schedule.size
    end

    def run_month(number, states)
      active = states.select(&:active?)
      # By identity: two states can be equal by value (identical debts).
      rows = {}.compare_by_identity
      active.each { |state| rows[state] = { starting: state.balance, interest: BigDecimal("0"), payment: BigDecimal("0") } }

      active.each do |state|
        interest = round(state.balance * state.debt.apr / 100 / 12)
        state.balance += interest
        rows[state][:interest] = interest
      end

      pool = extra_monthly + states.sum(BigDecimal("0")) { |state| state.cleared_in ? state.debt.minimum_payment : 0 }

      ordered(active).each do |state|
        payment = [ state.debt.minimum_payment, state.balance ].min
        pay(state, payment, rows, number)
        pool += state.debt.minimum_payment - payment if state.balance.zero?
      end

      # Snowball ranks on what is still owed after the minimums, so a debt a
      # minimum just cleared is not a target and a near-cleared one comes first.
      ordered(states.select(&:active?)).each do |state|
        break unless pool.positive?

        payment = [ pool, state.balance ].min
        pay(state, payment, rows, number)
        pool -= payment
      end

      record_month(number, rows)
    end

    def pay(state, payment, rows, number)
      state.balance -= payment
      rows[state][:payment] += payment
      return unless state.balance.zero?

      state.cleared_in = number
      payoff_order << state.debt.name
    end

    def record_month(number, rows)
      debt_months = rows.map do |state, row|
        DebtMonth.new(name: state.debt.name, starting_balance: row[:starting], interest: row[:interest],
                      payment: row[:payment], ending_balance: state.balance)
      end
      interest = debt_months.sum(BigDecimal("0"), &:interest)
      paid = debt_months.sum(BigDecimal("0"), &:payment)

      @total_interest += interest
      @total_paid += paid
      schedule << Month.new(number: number, total_paid: paid, interest: interest, debts: debt_months)
    end

    def ordered(states)
      case strategy
      when :avalanche then states.sort_by { |state| [ -state.debt.apr, state.debt.name ] }
      when :snowball then states.sort_by { |state| [ state.balance, state.debt.name ] }
      end
    end

    # A plan cannot finish when even the whole budget, were it all aimed at one
    # debt, would not outrun that debt's interest. Catches the common case
    # (no payment on a debt that accrues interest) before simulating.
    def raise_if_unpayable!
      budget = extra_monthly + debts.sum(BigDecimal("0")) { |debt| debt.minimum_payment }

      debts.each do |debt|
        next unless round(debt.balance * debt.apr / 100 / 12) >= budget

        raise NotConverging, "#{debt.name} accrues at least as much interest as can ever be paid towards it"
      end
    end

    def normalize_strategy(value)
      strategy = value.respond_to?(:to_sym) ? value.to_sym : nil
      return strategy if STRATEGIES.include?(strategy)

      raise ArgumentError, "strategy must be one of #{STRATEGIES.join(', ')}"
    end

    def normalize_debt(debt)
      Debt.new(
        name: debt.name.to_s,
        balance: money!(debt.balance, "balance"),
        apr: decimal!(debt.apr, "apr"),
        minimum_payment: money!(debt.minimum_payment, "minimum_payment")
      )
    end

    def money!(value, field)
      decimal!(value, field).round(CENTS, ROUNDING)
    end

    def decimal!(value, field)
      amount = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s, exception: false)
      raise ArgumentError, "#{field} must be a number" if amount.nil?
      raise ArgumentError, "#{field} must be finite" unless amount.finite?
      raise ArgumentError, "#{field} must not be negative" if amount.negative?

      amount
    end

    def round(amount)
      amount.round(CENTS, ROUNDING)
    end
end
