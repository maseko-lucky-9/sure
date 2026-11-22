class AddBudgetBucketToCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :categories, :budget_bucket, :string
  end
end
