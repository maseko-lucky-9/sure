require "test_helper"

class CategoriesBudgetBucketTest < ActionDispatch::IntegrationTest
  BUCKET_SELECT = "select[name='category[budget_bucket]']"

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    ensure_tailwind_build
  end

  test "the group select is offered for a top-level category when preview features are on" do
    preview(true)

    get edit_category_url(categories(:food_and_drink))

    assert_response :success
    assert_select BUCKET_SELECT do
      assert_select "option[value='']", text: "Automatic"
      assert_select "option[value='needs']", text: "Needs"
      assert_select "option[value='wants']", text: "Wants"
      assert_select "option[value='savings']", text: "Savings"
    end
  end

  test "the select names the default group of a default category" do
    preview(true)

    get edit_category_url(categories(:food_and_drink))

    assert_select "p", text: "Automatic: Wants"
  end

  test "there is no default hint for a category without a default group" do
    preview(true)

    get edit_category_url(categories(:one))

    assert_select BUCKET_SELECT
    assert_select "p", text: /Automatic:/, count: 0
  end

  test "the select is also on the new category form" do
    preview(true)

    get new_category_url

    assert_select BUCKET_SELECT
  end

  test "the select is not offered for a subcategory" do
    preview(true)

    get edit_category_url(categories(:subcategory))

    assert_response :success
    assert_select BUCKET_SELECT, count: 0
  end

  test "the select is not offered without preview features" do
    preview(false)

    get edit_category_url(categories(:food_and_drink))

    assert_response :success
    assert_select BUCKET_SELECT, count: 0
  end

  test "update stores the chosen group" do
    patch category_url(categories(:one)), params: { category: { budget_bucket: "savings" } }

    assert_redirected_to categories_url
    assert_equal "savings", categories(:one).reload.budget_bucket
  end

  test "choosing Automatic clears the group" do
    categories(:one).update!(budget_bucket: "needs")

    patch category_url(categories(:one)), params: { category: { budget_bucket: "" } }

    assert_redirected_to categories_url
    assert_nil categories(:one).reload.budget_bucket
  end

  test "an invalid group is rejected" do
    patch category_url(categories(:one)), params: { category: { budget_bucket: "luxuries" } }

    assert_response :unprocessable_entity
    assert_nil categories(:one).reload.budget_bucket
  end

  test "create stores the chosen group" do
    post categories_url, params: { category: { name: "Gym", color: "#123456", lucide_icon: "dumbbell", budget_bucket: "wants" } }

    assert_equal "wants", @family.categories.find_by!(name: "Gym").budget_bucket
  end

  private
    def preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end
