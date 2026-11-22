require "test_helper"

class Family::DataImporterBudgetBucketTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "restores a category's 50/30/20 group and drops a value it does not know" do
    ndjson = [
      { type: "Category", data: { id: "cat-1", name: "Pets", color: "#FF5733", budget_bucket: "needs" } },
      { type: "Category", data: { id: "cat-2", name: "Hobbies", color: "#33FF57", budget_bucket: "luxuries" } },
      { type: "Category", data: { id: "cat-3", name: "Older export", color: "#3357FF" } }
    ].map(&:to_json).join("\n")

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal "needs", @family.categories.find_by!(name: "Pets").budget_bucket
    assert_nil @family.categories.find_by!(name: "Hobbies").budget_bucket
    assert_nil @family.categories.find_by!(name: "Older export").budget_bucket
  end

  # An export made before the column existed has no key at all.
  test "an older export leaves an existing category's group alone" do
    @family.categories.create!(name: "Pets", color: "#FF5733", lucide_icon: "shapes", budget_bucket: "wants")
    ndjson = { type: "Category", data: { id: "cat-1", name: "Pets", color: "#FF5733" } }.to_json

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal "wants", @family.categories.find_by!(name: "Pets").budget_bucket
  end
end
