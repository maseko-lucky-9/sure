# Splits a period's income across needs, wants and savings, for comparison with
# the 50/30/20 rule. Plain Ruby over IncomeStatement::CategoryNetting's groups;
# it runs no queries.
#
# The groups are one per top-level category with refunds already netted, so a
# refund is set against its category's spending in the period (only a refund
# larger than that spending counts as income), and a subcategory's spending
# sits in its parent's group. Each group's spending goes
# to its category's effective budget bucket; a group with no bucket (and the
# synthetic rows) is "unassigned".
#
# Savings is measured from the other side: spending in savings categories PLUS
# whatever income was left over, so it is what was put away or never spent. It
# is negative when the period's spending was more than its income. Because of
# that, needs + wants + savings + unassigned always equals income.
#
# What the income statement leaves out is left out here too: transfers between
# the family's own accounts, card payments and transactions marked one-time.
#
# All amounts are BigDecimal in the family's currency; shares are percentages
# of income rounded to one decimal.
class IncomeStatement::NeedsWantsSavings
  TARGETS = { needs: 50, wants: 30, savings: 20 }.freeze

  Row = Data.define(:bucket, :amount, :share, :target_share, :target_amount, :difference)
  Unassigned = Data.define(:amount, :share, :categories)
  UnassignedCategory = Data.define(:name, :amount)

  attr_reader :income, :currency, :leftover, :rows, :unassigned

  # @param groups [Array<Hash>] IncomeStatement::CategoryNetting#groups
  # @param currency [String] the family currency the groups are in
  def initialize(groups:, currency:)
    @income = groups.sum(0.to_d) { |group| IncomeStatement::CategoryNetting.side_total(group, :income) }
    @currency = currency

    spending, unassigned_categories = top_level_spending(groups)
    @leftover = @income - spending.values.sum(0.to_d)
    @rows = available? ? build_rows(spending) : []
    @unassigned = build_unassigned(spending, unassigned_categories)
  end

  # False when income is zero or less: there is nothing to take a share of.
  def available?
    income.positive?
  end

  def needs = rows.find { |row| row.bucket == :needs }
  def wants = rows.find { |row| row.bucket == :wants }
  def savings = rows.find { |row| row.bucket == :savings }

  private
    # [spending per bucket (:needs, :wants, :savings, :unassigned), the
    # unassigned categories themselves], from each group's net spending.
    def top_level_spending(groups)
      unassigned_categories = []
      totals = Hash.new(0.to_d)

      groups.each do |group|
        category = group[:category]
        amount = IncomeStatement::CategoryNetting.side_total(group, :expense).to_d
        bucket = category.effective_budget_bucket&.to_sym

        if bucket
          totals[bucket] += amount
        else
          totals[:unassigned] += amount
          unassigned_categories << UnassignedCategory.new(name: category.display_name, amount: amount) if amount.nonzero?
        end
      end

      [ totals, unassigned_categories ]
    end

    def build_rows(spending)
      TARGETS.map do |bucket, target_share|
        amount = spending[bucket]
        amount += leftover if bucket == :savings
        target_amount = income * target_share / 100

        Row.new(
          bucket: bucket,
          amount: amount,
          share: share_of_income(amount),
          target_share: target_share,
          target_amount: target_amount,
          difference: amount - target_amount
        )
      end
    end

    def build_unassigned(spending, categories)
      amount = spending[:unassigned]

      Unassigned.new(
        amount: amount,
        share: available? ? share_of_income(amount) : 0.to_d,
        categories: categories.sort_by { |category| -category.amount }
      )
    end

    def share_of_income(amount)
      (amount * 100 / income).round(1)
    end
end
