require "test_helper"

class Transactions::CategorizesSuggestionTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @coffee = categories(:food_and_drink)
    @other = categories(:one)
    @family.accounts.each { |a| a.entries.delete_all }
  end

  def enable_preview!
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
  end

  def train_two_categories
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @other) }
  end

  def suggestion_node
    css_select("[data-testid='category-suggestion']").first
  end

  # What a browser submits when the given button is clicked: every named field
  # of the form in page order (checked boxes only, a select's first option when
  # none is chosen) plus the clicked button. Rack keeps the last value of a
  # repeated plain key, so where the button sits in the page matters.
  def submit_form_with(button)
    form = css_select("form#categorize-form").first
    pairs = form.css("input[name], select[name], button[name]").filter_map do |field|
      case field.name
      when "input"
        next if %w[checkbox radio].include?(field["type"]) && field["checked"].nil?
        [ field["name"], field["value"].to_s ]
      when "select"
        selected = field.at_css("option[selected]") || field.at_css("option")
        [ field["name"], selected ? selected["value"].to_s : "" ]
      else
        [ field["name"], field["value"].to_s ] if field.equal?(button)
      end
    end

    post transactions_categorize_url,
      params: URI.encode_www_form(pairs),
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
  end

  test "shows the suggested category with its confidence and a button that submits it" do
    enable_preview!
    train_two_categories
    create_transaction(account: @account, name: "Starbucks Coffee")

    get transactions_categorize_url

    assert_response :success
    assert_not_nil suggestion_node
    assert_match(/Suggested:\s*Food & Drink\s*·\s*\d{1,3}% match/, suggestion_node.text.squish)

    button = suggestion_node.at_css("button[type='submit'][name='category_id']")
    assert_not_nil button
    assert_equal @coffee.id, button["value"]
    assert_equal "Use Food & Drink", button.text.squish
  end

  test "the accept button comes after every row select so its category is the one submitted" do
    enable_preview!
    train_two_categories
    2.times { create_transaction(account: @account, name: "Starbucks Coffee") }

    get transactions_categorize_url

    named = css_select("form#categorize-form [name='category_id']").to_a
    button = suggestion_node.at_css("button[name='category_id']")
    last_select = named.rindex { |node| node.name == "select" }

    assert_not_nil last_select
    assert_operator named.index(button), :>, last_select
  end

  test "accepting the suggestion categorises the group's entries and creates the rule when ticked" do
    enable_preview!
    train_two_categories
    entries = 3.times.map { create_transaction(account: @account, name: "Starbucks Coffee") }

    get transactions_categorize_url
    button = suggestion_node.at_css("button[name='category_id']")

    assert_difference "Rule.count", 1 do
      submit_form_with(button)
    end

    assert_response :redirect
    assert_equal [ @coffee.id ], entries.map { |entry| entry.entryable.reload.category_id }.uniq
  end

  test "accepting the suggestion with the rule box unticked creates no rule" do
    enable_preview!
    train_two_categories
    entry = create_transaction(account: @account, name: "Starbucks Coffee")

    get transactions_categorize_url
    button = suggestion_node.at_css("button[name='category_id']")

    assert_no_difference "Rule.count" do
      submit_form_with(button)
    end

    assert_equal @coffee.id, entry.entryable.reload.category_id
  end

  # The guess was made for the group on screen. Once the rule filter is edited
  # the list holds other transactions, so the shortcut must go.
  test "editing the rule filter removes the suggestion" do
    enable_preview!
    train_two_categories
    create_transaction(account: @account, name: "Starbucks Coffee")

    get transactions_categorize_url
    assert_equal "categorize_suggestion", suggestion_node["id"]

    get preview_rule_transactions_categorize_url(filter: "Amazon"), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action=remove][target=categorize_suggestion]", count: 1
  end

  test "shows no suggestion with preview features off" do
    train_two_categories
    create_transaction(account: @account, name: "Starbucks Coffee")

    get transactions_categorize_url

    assert_response :success
    assert_nil suggestion_node
    assert_no_match(/Suggested:/, response.body)
  end

  test "shows no suggestion and still renders with too little training data" do
    enable_preview!
    3.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    create_transaction(account: @account, name: "Starbucks Coffee")

    get transactions_categorize_url

    assert_response :success
    assert_nil suggestion_node
    assert_select "button[name='category_id']"
  end
end
