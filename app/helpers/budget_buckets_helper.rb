# Labels and wording for the needs / wants / savings grouping, shared by the
# category form and the Reports section.
module BudgetBucketsHelper
  def budget_bucket_label(bucket)
    t("categories.budget_buckets.#{bucket}")
  end

  def budget_bucket_options
    Category::BUDGET_BUCKETS.map { |bucket| [ budget_bucket_label(bucket), bucket ] }
  end

  # Names the group a default category gets when none is chosen, or nil.
  def budget_bucket_hint(category)
    default = category.default_budget_bucket
    return if default.blank?

    t("categories.form.budget_bucket_default", group: budget_bucket_label(default))
  end

  # How far a group is from its 50/30/20 target, in words as well as a sign:
  # "+$400 over", "-$300 under", or "On target" when it rounds to nothing.
  def budget_bucket_difference(row, currency)
    difference = row.difference.round(0)
    return t("reports.needs_wants_savings.on_target") if difference.zero?

    sign = difference.positive? ? "+" : "-"
    amount = "#{sign}#{Money.new(difference.abs, currency).format(precision: 0)}"

    t(difference.positive? ? "reports.needs_wants_savings.over" : "reports.needs_wants_savings.under", amount: amount)
  end

  # One line of the Reports table: the first and second lines of its last
  # column are already formatted, since they differ between a group (distance
  # from target) and the unassigned line (which categories, and where to fix it).
  BudgetBucketRow = Data.define(:testid, :label, :amount, :share, :primary, :secondary)

  # Needs, wants and savings, then the unassigned spending when there is any.
  def budget_bucket_table_rows(breakdown)
    rows = breakdown.rows.map do |row|
      BudgetBucketRow.new(
        testid: "nws-#{row.bucket}",
        label: budget_bucket_label(row.bucket),
        amount: row.amount,
        share: row.share,
        primary: budget_bucket_difference(row, breakdown.currency),
        secondary: tag.span(t("reports.needs_wants_savings.target",
                              share: number_to_percentage(row.target_share, precision: 0),
                              amount: Money.new(row.target_amount, breakdown.currency).format(precision: 0)),
                            class: "privacy-sensitive")
      )
    end

    unassigned = breakdown.unassigned
    return rows if unassigned.amount.zero?

    rows << BudgetBucketRow.new(
      testid: "nws-unassigned",
      label: t("reports.needs_wants_savings.unassigned"),
      amount: unassigned.amount,
      share: unassigned.share,
      primary: budget_bucket_unassigned_names(unassigned),
      secondary: render(DS::Link.new(text: t("reports.needs_wants_savings.assign_groups"), variant: :default, href: categories_path))
    )
  end

  # The largest few unassigned categories, as "A, B and C", or "A, B, C and 2 more".
  def budget_bucket_unassigned_names(unassigned, limit: 3)
    names = unassigned.categories.map(&:name)
    rest = names.size - limit
    return names.to_sentence unless rest.positive?

    "#{names.first(limit).join(", ")} #{t("reports.needs_wants_savings.and_more", count: rest)}"
  end
end
