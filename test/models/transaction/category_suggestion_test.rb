require "test_helper"

class Transaction::CategorySuggestionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    # Fresh family: fixture families carry categorized transactions that would
    # pollute the training set.
    @family = Family.create!(name: "Suggestion Family")
    @account = @family.accounts.create!(name: "Suggestion test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
  end

  def train_two_categories
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
  end

  def uncategorized_group(count = 1, name: "Starbucks Coffee")
    Array.new(count) { create_transaction(account: @account, name: name) }
  end

  # A categorizer that is trained as far as the suggestion can tell, with the
  # probabilities handed in per transaction.
  def stubbed_categorizer(probabilities_by_entry)
    categorizer = Family::BayesCategorizer.new(@family)
    categorizer.stubs(:enough_training_data?).returns(true)
    probabilities_by_entry.each do |entry, probabilities|
      categorizer.stubs(:probabilities).with(entry.entryable).returns(probabilities)
    end
    categorizer
  end

  def suggest(entries, categorizer: nil)
    Transaction::CategorySuggestion.for(@family, entries, categorizer: categorizer)
  end

  test "is nil without enough training data" do
    5.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }

    assert_nil suggest(uncategorized_group)
  end

  test "suggests the trained category for a clearly matching name" do
    train_two_categories

    suggestion = suggest(uncategorized_group(3))

    assert_equal @coffee, suggestion.category
    assert_operator suggestion.confidence, :>, 0.9
    assert_operator suggestion.confidence, :<=, 1.0
  end

  test "is nil for an empty group and does not train a categorizer for it" do
    train_two_categories
    Family::BayesCategorizer.expects(:new).never

    assert_nil suggest([])
  end

  test "is nil when nothing in the name is known to the model" do
    train_two_categories

    assert_nil suggest(uncategorized_group(name: "Zzyzx Blorptronics"))
  end

  test "the floor is inclusive: 0.30 suggests, 0.29 does not" do
    entry = uncategorized_group.first

    assert_nil suggest([ entry ], categorizer: stubbed_categorizer(entry => { @coffee.id => 0.29, @groceries.id => 0.28 }))

    suggestion = suggest([ entry ], categorizer: stubbed_categorizer(entry => { @coffee.id => 0.30, @groceries.id => 0.28 }))
    assert_equal @coffee, suggestion.category
    assert_in_delta 0.30, suggestion.confidence, 1e-9
  end

  test "a group takes the category with the highest mean probability, not the highest single score" do
    one, two, three = uncategorized_group(3)
    categorizer = stubbed_categorizer(
      one => { @coffee.id => 0.9, @groceries.id => 0.1 },
      two => { @coffee.id => 0.8, @groceries.id => 0.2 },
      three => { @coffee.id => 0.0, @groceries.id => 1.0 }
    )

    suggestion = suggest([ one, two, three ], categorizer: categorizer)

    assert_equal @coffee, suggestion.category
    assert_in_delta (0.9 + 0.8 + 0.0) / 3, suggestion.confidence, 1e-9
  end

  test "a transaction the model knows nothing about counts as zero in the mean" do
    known, unknown = uncategorized_group(2)
    categorizer = stubbed_categorizer(known => { @coffee.id => 0.9 }, unknown => {})

    suggestion = suggest([ known, unknown ], categorizer: categorizer)

    assert_equal @coffee, suggestion.category
    assert_in_delta 0.45, suggestion.confidence, 1e-9
  end

  test "scores only the first transactions of a large group" do
    entries = uncategorized_group(Transaction::CategorySuggestion::MAX_TRANSACTIONS_SCORED + 2)
    categorizer = Family::BayesCategorizer.new(@family)
    categorizer.stubs(:enough_training_data?).returns(true)
    categorizer.expects(:probabilities).times(Transaction::CategorySuggestion::MAX_TRANSACTIONS_SCORED).returns({ @coffee.id => 0.9 })

    assert_equal @coffee, suggest(entries, categorizer: categorizer).category
  end

  test "builds one categorizer however many transactions the group has" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)
    Family::BayesCategorizer.expects(:new).once.returns(categorizer)

    assert_equal @coffee, suggest(uncategorized_group(5)).category
  end

  # The suggestion is an optional hint: a classifier error must not take the
  # walkthrough down with it.
  test "is nil and logs when the classifier raises" do
    entries = uncategorized_group
    categorizer = Family::BayesCategorizer.new(@family)
    categorizer.stubs(:enough_training_data?).raises(ZeroDivisionError, "divided by 0")

    assert_difference -> { DebugLogEntry.where(category: "categorization").count }, 1 do
      assert_nil suggest(entries, categorizer: categorizer)
    end
  end

  test "never suggests a category the classifier excludes" do
    entry = uncategorized_group.first
    categorizer = stubbed_categorizer(entry => { @coffee.id => 0.6, @groceries.id => 0.4 })
    categorizer.stubs(:excluded_category_ids).returns([ @coffee.id ])

    suggestion = suggest([ entry ], categorizer: categorizer)

    assert_equal @groceries, suggestion.category
    assert_in_delta 0.4, suggestion.confidence, 1e-9
  end

  test "never suggests a category outside the family" do
    entry = uncategorized_group.first
    foreign = categories(:food_and_drink)
    assert_not_equal @family.id, foreign.family_id
    categorizer = stubbed_categorizer(entry => { foreign.id => 0.7, @coffee.id => 0.3 })

    assert_equal @coffee, suggest([ entry ], categorizer: categorizer).category
  end

  test "is read-only: it changes no transaction and writes no enrichment" do
    train_two_categories
    entries = uncategorized_group(3)
    before = entries.map { |entry| [ entry.entryable.reload.category_id, entry.entryable.updated_at, entry.reload.updated_at ] }

    assert_no_difference [ "DataEnrichment.count", "Transaction.count", "Entry.count" ] do
      assert suggest(entries)
    end

    after = entries.map { |entry| [ entry.entryable.reload.category_id, entry.entryable.updated_at, entry.reload.updated_at ] }
    assert_equal before, after
    assert entries.all? { |entry| entry.entryable.category_id.nil? }
  end
end
