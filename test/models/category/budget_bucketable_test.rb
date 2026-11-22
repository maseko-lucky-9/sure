require "test_helper"

class Category::BudgetBucketableTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "a budget bucket is optional and limited to needs, wants and savings" do
    assert_equal %w[needs wants savings], Category::BUDGET_BUCKETS

    Category::BUDGET_BUCKETS.each do |bucket|
      assert build_category(budget_bucket: bucket).valid?, "#{bucket} should be valid"
    end
    assert build_category(budget_bucket: nil).valid?

    junk = build_category(budget_bucket: "luxuries")
    assert_not junk.valid?
    assert junk.errors.of_kind?(:budget_bucket, :inclusion)
  end

  test "a blank bucket from the form is stored as nil" do
    category = build_category(budget_bucket: "")
    assert category.valid?
    assert_nil category.budget_bucket

    category.save!
    assert_nil category.reload.budget_bucket
  end

  test "a category's own bucket is its effective bucket" do
    assert_equal "wants", build_category(budget_bucket: "wants").effective_budget_bucket
  end

  test "an unassigned custom category has no bucket" do
    custom = build_category(name: "Side hustle")

    assert_nil custom.effective_budget_bucket
    assert_nil custom.default_budget_bucket
  end

  test "a default category falls back to its default bucket" do
    {
      "groceries" => "needs",
      "healthcare" => "needs",
      "food_and_drink" => "wants",
      "subscriptions" => "wants",
      "savings_and_investments" => "savings"
    }.each do |key, bucket|
      category = build_category(name: I18n.t("models.category.defaults.#{key}"))
      assert_equal bucket, category.effective_budget_bucket, key
      assert_equal bucket, category.default_budget_bucket, key
    end
  end

  test "every default category key is either mapped to a bucket or deliberately left out" do
    left_out = %w[income services]
    mapped = Category::DEFAULT_BUDGET_BUCKETS.keys.map { |key| key.delete_prefix("models.category.defaults.") }

    unmapped = Category::DEFAULT_CATEGORY_TRANSLATION_KEYS - mapped - left_out
    assert_empty unmapped
    assert_equal "savings", Category::DEFAULT_BUDGET_BUCKETS.fetch(Category::INVESTMENT_CONTRIBUTIONS_NAME_KEY)
    assert Category::DEFAULT_BUDGET_BUCKETS.values.all? { |bucket| Category::BUDGET_BUCKETS.include?(bucket) }
    assert_predicate Category::DEFAULT_BUDGET_BUCKETS, :frozen?
  end

  test "services and income have no default bucket" do
    %w[services income].each do |key|
      assert_nil build_category(name: I18n.t("models.category.defaults.#{key}")).effective_budget_bucket, key
    end
  end

  test "the investment contributions default is savings" do
    assert_equal "savings", build_category(name: I18n.t("models.category.investment_contributions")).effective_budget_bucket
  end

  test "a default name stored in another locale still gets its default bucket" do
    spanish_groceries = I18n.t("models.category.defaults.groceries", locale: :es)
    spanish_entertainment = I18n.t("models.category.defaults.entertainment", locale: :es)
    assert_not_equal I18n.t("models.category.defaults.groceries"), spanish_groceries

    assert_equal "needs", build_category(name: spanish_groceries).effective_budget_bucket
    assert_equal "wants", build_category(name: spanish_entertainment).effective_budget_bucket
  end

  test "a renamed default category has no default bucket" do
    assert_nil build_category(name: "Groceries (Checkers)").effective_budget_bucket
  end

  test "an own bucket overrides the default" do
    groceries = build_category(name: I18n.t("models.category.defaults.groceries"), budget_bucket: "wants")

    assert_equal "wants", groceries.effective_budget_bucket
    assert_equal "needs", groceries.default_budget_bucket
  end

  test "a subcategory follows its parent, even when it has a bucket of its own" do
    parent = create_category(name: "Household", budget_bucket: "needs")
    plain_child = create_category(name: "Cleaning", parent: parent)
    opinionated_child = create_category(name: "Candles", parent: parent, budget_bucket: "wants")

    assert_equal "needs", plain_child.effective_budget_bucket
    assert_equal "needs", opinionated_child.effective_budget_bucket
  end

  test "a subcategory follows its parent's default" do
    parent = create_category(name: I18n.t("models.category.defaults.entertainment"))
    child = create_category(name: "Streaming", parent: parent)

    assert_equal "wants", child.effective_budget_bucket
  end

  test "a subcategory of an unassigned parent has no bucket" do
    parent = create_category(name: "Misc")
    child = create_category(name: "Odds", parent: parent, budget_bucket: "savings")

    assert_nil child.effective_budget_bucket
  end

  test "the synthetic categories have no default bucket" do
    assert_nil Category.uncategorized.effective_budget_bucket
    assert_nil Category.other_investments.effective_budget_bucket
  end

  private
    def build_category(name: "Test category", **attributes)
      @family.categories.build(name: name, color: "#123456", lucide_icon: "shapes", **attributes)
    end

    def create_category(**attributes)
      build_category(**attributes).tap(&:save!)
    end
end
