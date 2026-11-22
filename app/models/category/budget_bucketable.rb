# Groups a category as needs, wants or savings for the 50/30/20 view in Reports.
# A category's own choice always wins; a default is only a read-time fallback
# and is never written, so changing a default never rewrites stored data.
module Category::BudgetBucketable
  extend ActiveSupport::Concern

  BUDGET_BUCKETS = %w[needs wants savings].freeze

  # Default bucket by the i18n key of a default category's name. Services and
  # income are left out on purpose: services can be either, and income is not
  # spending.
  DEFAULT_BUDGET_BUCKETS = {
    "needs" => %w[groceries transportation healthcare mortgage_rent utilities insurance taxes loan_payments fees],
    "wants" => %w[food_and_drink shopping travel entertainment personal_care home_improvement subscriptions
                  sports_and_fitness gifts_and_donations],
    "savings" => %w[savings_and_investments]
  }.each_with_object({ Category::INVESTMENT_CONTRIBUTIONS_NAME_KEY => "savings" }) do |(bucket, keys), map|
    keys.each { |key| map["models.category.defaults.#{key}"] = bucket }
  end.freeze

  included do
    normalizes :budget_bucket, with: ->(value) { value.presence }

    validates :budget_bucket, inclusion: { in: BUDGET_BUCKETS }, allow_nil: true
  end

  # The bucket this category counts toward: a subcategory follows its parent
  # (its spending is already inside the parent's total), otherwise the
  # category's own choice, otherwise the default for its name, otherwise nil.
  def effective_budget_bucket
    owner = subcategory? ? parent : self

    owner.budget_bucket || owner.default_budget_bucket
  end

  # The bucket a default category gets when none is chosen. Matches the stored
  # name in any supported locale; a renamed or user-created category has none.
  def default_budget_bucket
    i18n_key = self.class.send(:default_category_translation_key_for, name)

    DEFAULT_BUDGET_BUCKETS[i18n_key]
  end
end
