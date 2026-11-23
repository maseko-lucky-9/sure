class TransactionImport < Import
  SURE_EXPORT_SETTINGS = {
    amount_type_strategy: "signed_amount",
    signage_convention: "inflows_negative",
    date_format: "%Y-%m-%d",
    number_format: "1,234.56",
    rows_to_skip: 0
  }.freeze

  # The column label for each column of Family::DataExporter::TRANSACTIONS_CSV_HEADERS, in its order.
  SURE_EXPORT_LABELS = %i[
    date_col_label account_col_label amount_col_label name_col_label
    category_col_label tags_col_label notes_col_label currency_col_label
  ].zip(Family::DataExporter::TRANSACTIONS_CSV_HEADERS).to_h.freeze

  # Optional columns for bank exports that split an amount into Money In (the
  # mapped amount column), Money Out and Fee. Kept in column_mappings.
  MONEY_COLUMN_KEYS = %w[outflow_col_label fee_col_label].freeze

  # Money in is emitted positive and money out negative, which is what these
  # settings turn into Sure's stored sign (money in negative, money out positive).
  MONEY_OUT_SIGN_SETTINGS = { amount_type_strategy: "signed_amount", signage_convention: "inflows_positive" }.freeze

  # A currency symbol or code before the number, after an optional minus.
  CURRENCY_PREFIX = /\A(-?)\p{Space}*(?:ZAR|R|\$|€|£)\p{Space}*/i

  # Runs before validation so a leftover custom_column strategy cannot fail the
  # inflow-value check on an import that no longer uses it.
  before_validation :force_money_out_sign_settings, if: :money_out_column?

  # A new file or header row can leave the saved money columns without a header.
  # An upload saves without validation and the configure step's rows_to_skip
  # refresh saves only that number, so both drop the columns instead of failing
  # later. before_save covers every save path; before_validation lets a validated
  # save drop them before the checks below look at them.
  before_validation :drop_money_columns_missing_from_headers
  before_save :drop_money_columns_missing_from_headers
  after_validation { @money_columns_assigned = false }
  after_save { @money_columns_assigned = false }

  # Only a save that touches what these checks are about runs them, so an
  # unrelated update (account, status) on an import with a stale mapping cannot
  # fail, whatever route it takes.
  validate :money_columns_are_usable, if: :money_column_inputs_changed?

  MONEY_COLUMN_KEYS.each do |key|
    define_method(key) { column_mappings&.dig(key) }

    # A blank choice removes the key; other column_mappings entries stay.
    define_method("#{key}=") do |label|
      @money_columns_assigned = true
      updated = (column_mappings || {}).except(key)
      updated[key] = label if label.present?
      self.column_mappings = updated.presence
    end
  end

  def money_out_column?
    outflow_col_label.present?
  end

  # With a Money Out column chosen, each line becomes one row per movement:
  # money in, money out, then the fee. Without one, the base class reads the
  # single amount column as it always has. A configuration the file cannot
  # satisfy raises RecordInvalid, as the base does for duplicate headers, before
  # any existing row is touched.
  def generate_rows_from_csv
    return super unless money_out_column? || fee_col_label.present?

    refuse_unusable_money_columns!
    rows.destroy_all

    mapped_rows = csv_rows.flat_map { |csv_row| money_line_rows(csv_row) }
    mapped_rows.each.with_index(1) { |row, number| row[:source_row_number] = number }

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  # Money columns come across only when this file has them. When they do not, the
  # template's sign convention was forced by them rather than chosen, so it is not
  # copied either: the import keeps its own, editable on the configure step.
  def template_attributes(import_template)
    attributes = super.merge("column_mappings" => template_column_mappings(import_template))
    template_money_columns = import_template.column_mappings.to_h.slice(*MONEY_COLUMN_KEYS)
    carried = attributes["column_mappings"].to_h.slice(*MONEY_COLUMN_KEYS)
    template_money_columns.present? && carried.empty? ? attributes.except("signage_convention") : attributes
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new # Track entries we've already claimed in this import

      rows.each_with_index do |row, index|
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        # Guard against nil account - this happens when an account name in CSV is not mapped
        if mapped_account.nil?
          row_number = index + 1
          account_name = row.account.presence || "(blank)"
          error_message = "Row #{row_number}: Account '#{account_name}' is not mapped to an existing account. " \
                         "Please map this account in the import configuration."
          errors.add(:base, error_message)
          raise Import::MappingError, error_message
        end

        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        # Use account's currency when no currency column was mapped in CSV, with family currency as fallback
        effective_currency = currency_col_label.present? ? row.currency : (mapped_account.currency.presence || family.currency)

        # Check for duplicate transactions using the adapter's deduplication logic
        # Pass claimed_entry_ids to exclude entries we've already matched in this import
        # This ensures identical rows within the CSV are all imported as separate transactions
        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: effective_currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          # Update existing transaction instead of creating a new one. It keeps
          # its original import (if any): the entry belongs to whoever created
          # it, so reverting or deleting this import must not destroy it.
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          new_transactions << Transaction.new(
            category: category,
            tags: tags,
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        end
      end

      # Save updated entries first
      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      # Bulk import new transactions
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    base = %i[date amount name currency category tags notes]
    base.unshift(:account) if account.nil?
    base
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def selectable_amount_type_values
    return [] if entity_type_col_label.nil?

    csv_rows.map { |row| row[entity_type_col_label] }.uniq
  end

  def csv_template
    template = <<~CSV
      date*,amount*,name,currency,category,tags,account,notes
      2024-05-15,-45.99,Grocery Store,USD,Food,groceries|essentials,Checking Account,Monthly grocery run
      2024-05-16,1500.00,Salary,,Income,,Main Account,
      2024-05-17,-12.50,Coffee Shop,,,coffee,,
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  # Sure's own transactions.csv export keeps the stored sign (outflows positive),
  # ISO dates and plain decimals, so a re-import of it needs matching settings.
  # Call after assigning a new raw_file_str and before saving it.
  def preset_for_uploaded_csv
    if sure_export_csv?(raw_file_str, col_sep)
      assign_attributes(SURE_EXPORT_SETTINGS)
      # A money out column would force the sign settings back on the next save.
      MONEY_COLUMN_KEYS.each { |key| public_send("#{key}=", nil) }
    elsif sure_export_csv?(raw_file_str_was, col_sep_was)
      assign_attributes(amount_type_strategy: "signed_amount", signage_convention: "inflows_positive", date_format: family.date_format)
    end
  end

  # A template from another bank's file would bring its own sign, formats,
  # column names and skipped rows, none of which fit a Sure export.
  def apply_template!(import_template)
    return super unless sure_export_csv?(raw_file_str, col_sep)

    update!(
      template_attributes(import_template)
        .merge(SURE_EXPORT_SETTINGS.stringify_keys, sure_export_labels.stringify_keys)
        .merge("column_mappings" => column_mappings&.except(*MONEY_COLUMN_KEYS)&.presence)
    )
  end

  private
    def force_money_out_sign_settings
      assign_attributes(MONEY_OUT_SIGN_SETTINGS)
    end

    # The template's money columns replace this import's; its other mappings
    # stay. They come across only when this file has all of the columns, so a
    # statement with other headers is not left with a configuration that cannot
    # be applied.
    def template_column_mappings(import_template)
      money_columns = import_template.column_mappings.to_h.slice(*MONEY_COLUMN_KEYS)
      labels = [ import_template.amount_col_label, *money_columns.values ]
      money_columns = {} unless labels.all? { |label| file_has_column?(label, skip: import_template.rows_to_skip) }
      (column_mappings || {}).except(*MONEY_COLUMN_KEYS).merge(money_columns).presence
    end

    def money_column_inputs_changed?
      @money_columns_assigned || will_save_change_to_column_mappings? || will_save_change_to_amount_col_label? || headers_will_change?
    end

    def headers_will_change?
      will_save_change_to_raw_file_str? || will_save_change_to_col_sep? || will_save_change_to_rows_to_skip?
    end

    # When this save brings a new file, separator or header row and does not itself
    # choose the money columns, the saved ones are dropped if any of them has no
    # header now. The sign settings are left as they are: they are the defaults the
    # forced values equal, and the configure step the user lands on shows them
    # editable. Rows already generated are not touched, as for any other import.
    def drop_money_columns_missing_from_headers
      return if @money_columns_assigned || !money_out_column? || !uploaded? || !headers_will_change?
      return if money_column_labels.all? { |label| file_has_column?(label) }

      self.column_mappings = column_mappings.except(*MONEY_COLUMN_KEYS).presence
    end

    def money_column_labels
      [ amount_col_label, outflow_col_label, fee_col_label ].compact_blank
    end

    def money_columns_are_usable
      money_column_problems.each { |problem| errors.add(:base, problem) }
    end

    def refuse_unusable_money_columns!
      problems = money_column_problems
      return if problems.empty?

      problems.each { |problem| errors.add(:base, problem) }
      raise ActiveRecord::RecordInvalid, self
    end

    # Messages for a fee without a money out column, one column in two roles, or
    # a chosen column the uploaded file does not have.
    def money_column_problems
      return [ I18n.t("imports.errors.fee_requires_money_out") ] if fee_col_label.present? && !money_out_column?
      return [] unless money_out_column?

      roles = { amount: amount_col_label, outflow: outflow_col_label, fee: fee_col_label }.compact_blank
      clashes = roles.to_a.combination(2).select { |(_, a), (_, b)| normalize_header(a) == normalize_header(b) }
      return clashes.map { |(first, label), (second, _)| I18n.t("imports.errors.money_columns_clash", first: role_name(first), second: role_name(second), label: label) } if clashes.any?
      return [] unless uploaded?

      roles.reject { |_, label| file_has_column?(label) }
           .map { |role, label| I18n.t("imports.errors.money_column_missing", role: role_name(role), label: label) }
    end

    def role_name(role)
      I18n.t("imports.errors.money_column_roles.#{role}")
    end

    def file_has_column?(label, skip: rows_to_skip)
      file_headers(skip).any? { |header| normalize_header(header) == normalize_header(label) }
    end

    # The headers of the file as it stands now, which csv_headers may not reflect
    # if it was read before the file, separator or rows_to_skip changed.
    def file_headers(skip)
      key = [ raw_file_str.hash, col_sep, skip.to_i ]
      return @file_headers.last if @file_headers&.first == key

      content = raw_file_str.to_s
      content = content.lines.drop(skip.to_i).join if skip.to_i > 0
      headers = begin
        self.class.parse_csv_str(content, col_sep: col_sep).headers
      rescue CSV::MalformedCSVError
        []
      end
      (@file_headers = [ key, headers ]).last
    end

    # The rows for one CSV line. A cell is nil when blank and "" when it is not a
    # number written in the import's number_format. An unreadable amount keeps its
    # line as one row with a blank amount, which the clean step flags and which
    # blocks publishing, rather than guessing or dropping money. Money in keeps its
    # sign, so a negative Money In is an outflow (the signed reading, money in minus
    # |money out|); money out and fee are always outflows, by absolute value.
    def money_line_rows(csv_row)
      line = {
        account: csv_value(csv_row, account_col_label, "account", "account_name").to_s,
        date: csv_value(csv_row, date_col_label, "date").to_s,
        currency: (csv_value(csv_row, currency_col_label, "currency") || default_currency).to_s,
        category: csv_value(csv_row, category_col_label, "category").to_s,
        tags: csv_value(csv_row, tags_col_label, "tags").to_s,
        notes: csv_value(csv_row, notes_col_label, "notes").to_s
      }
      name = (csv_value(csv_row, name_col_label, "name") || default_row_name).to_s
      money_in, money_out, fee = [ amount_col_label, outflow_col_label, fee_col_label ].map { |label| sanitized_cell(csv_row, label) }

      return [ line.merge(name: name, amount: "") ] if [ money_in, money_out, fee ].include?("")

      movements = []
      movements << [ name, money_in ] if money_in.to_d.nonzero?
      movements << [ name, outflow(money_out) ] if money_out.to_d.nonzero?
      movements << [ movements.empty? ? name : "#{name} Fee", outflow(fee) ] if fee.to_d.nonzero?

      movements.map { |movement_name, amount| line.merge(name: movement_name, amount: amount) }
    end

    # Only the mapped column is read: no fallback to an "amount" or "balance" header.
    def sanitized_cell(csv_row, label)
      raw = csv_value(csv_row, label)
      return if raw.nil?

      cell = well_formed_number(raw)
      cell ? sanitize_number(cell) : ""
    end

    # The cell without its surrounding space and leading currency, when what is
    # left is exactly a number in the import's number_format: an optional ASCII
    # minus, digits grouped by that format's delimiter and an optional decimal
    # part with its separator. The base sanitiser strips whatever else it finds,
    # which would turn "(50.00)" or "50.00-" into a positive 50.
    def well_formed_number(raw)
      format = NUMBER_FORMATS[number_format]
      return unless format

      cell = raw.to_s.gsub(/\A\p{Space}+|\p{Space}+\z/, "").sub(CURRENCY_PREFIX) { Regexp.last_match(1) }
      cell if cell.match?(number_pattern(format))
    end

    # A space delimiter also means the no-break and narrow no-break spaces, as in
    # Import#sanitize_number.
    def number_pattern(format)
      delimiter = format[:delimiter]
      group = delimiter == " " ? "[ \u00A0\u202F]" : Regexp.escape(delimiter)
      integer = delimiter.empty? ? "\\d+" : "\\d{1,3}(?:#{group}\\d{3})+|\\d+"
      fraction = format[:separator].empty? ? "" : "(?:#{Regexp.escape(format[:separator])}\\d+)?"
      /\A-?(?:#{integer})#{fraction}\z/
    end

    def outflow(amount)
      "-#{amount.delete_prefix("-")}"
    end

    def sure_export_csv?(csv_str, separator)
      # A dropped file is read as binary bytes; read it as UTF-8 so a BOM or
      # non-ASCII characters elsewhere in the file cannot raise.
      headers = header_record(utf8_without_bom(csv_str), separator).map { |header| export_header_key(header) }
      headers.any? && (Family::DataExporter::TRANSACTIONS_CSV_HEADERS - headers).empty?
    end

    # Column labels must match the parsed headers exactly, which keep a BOM and
    # the file's own spelling (e.g. "Date"), so map each export column to it.
    # Read from the file itself: a Sure export skips no rows, whatever
    # rows_to_skip the import had before the template reset it.
    def sure_export_labels
      headers = header_record(raw_file_str, col_sep)
      SURE_EXPORT_LABELS.transform_values do |label|
        headers.find { |header| export_header_key(header) == label } || label
      end
    end

    # The first CSV record, read like Import.parse_csv_str reads headers:
    # leading blank lines are skipped and a quoted field may span lines.
    def header_record(csv_str, separator)
      CSV.new(csv_str.to_s.strip, col_sep: separator.presence || ",", liberal_parsing: true).shift.to_a
    rescue CSV::MalformedCSVError
      []
    end

    def export_header_key(header)
      utf8_without_bom(header).strip.downcase
    end

    def utf8_without_bom(str)
      str.to_s.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("\uFEFF")
    end
end
