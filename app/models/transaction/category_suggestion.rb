# Best-guess category for a group of uncategorized transactions, for the
# categorize walkthrough to offer as a one-tap shortcut. Read-only: it scores
# with Family::BayesCategorizer#probabilities and writes nothing.
class Transaction::CategorySuggestion
  Result = Data.define(:category, :confidence) do
    def percent
      (confidence * 100).round
    end
  end

  # Below this a guess among many categories is noise, so nothing is offered.
  # Deliberately lower than the classifier's auto-apply threshold: a person
  # confirms this one, they are not bound by it.
  MIN_CONFIDENCE = 0.30

  # Bounds the scoring cost for a large group; a group shares a merchant or
  # name, so its first transactions say as much as the rest.
  MAX_TRANSACTIONS_SCORED = 20

  # entries: the group's Entry records. categorizer: pass one to reuse a
  # trained instance; training loads up to 5,000 transactions, so build once.
  def self.for(family, entries, categorizer: nil)
    new(family, entries, categorizer: categorizer).call
  end

  def initialize(family, entries, categorizer: nil)
    @family = family
    @entries = entries
    @categorizer = categorizer
  end

  # Result, or nil when there is no usable guess. The suggestion is an optional
  # hint, so a classifier failure is logged and reads as "no guess".
  def call
    suggest
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "categorization",
      level: "warn",
      message: "Category suggestion failed: #{e.class} - #{e.message}",
      source: "bayes",
      family: @family
    )
    nil
  end

  private

    def suggest
      transactions = scored_transactions
      return nil if transactions.empty?

      categorizer = @categorizer ||= Family::BayesCategorizer.new(@family)
      return nil unless categorizer.enough_training_data?

      # A transaction the model knows nothing about contributes zero, so one
      # unknown name in a group lowers the mean instead of being ignored.
      totals = Hash.new(0.0)
      transactions.each do |transaction|
        categorizer.probabilities(transaction).each { |category_id, probability| totals[category_id] += probability }
      end

      candidates = totals.except(*categorizer.excluded_category_ids)
      categories = @family.categories.where(id: candidates.keys).index_by(&:id)
      category_id, total = candidates.select { |id, _| categories.key?(id) }.max_by { |_, sum| sum }
      return nil if category_id.nil?

      confidence = total / transactions.size
      return nil if confidence < MIN_CONFIDENCE

      Result.new(category: categories.fetch(category_id), confidence: confidence)
    end

    # The first MAX_TRANSACTIONS_SCORED transactions in the group's order, with
    # the associations the categorizer reads loaded in one go.
    def scored_transactions
      ids = @entries.lazy
        .select { |entry| entry.entryable_type == "Transaction" }
        .first(MAX_TRANSACTIONS_SCORED)
        .map(&:entryable_id)
      return [] if ids.empty?

      @family.transactions.where(id: ids).preload(:entry, :merchant).sort_by { |transaction| ids.index(transaction.id) }
    end
end
