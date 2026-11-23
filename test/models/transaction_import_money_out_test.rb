require "test_helper"

# Bank exports with separate Money In, Money Out and Fee columns (plus a running
# Balance). The three columns become one signed amount per row: money in is
# read as positive and Import::Row flips it into Sure's stored sign.
class TransactionImportMoneyOutTest < ActiveSupport::TestCase
  FIXTURE_DIR = Rails.root.join("tools/sa-statement-converter/fixtures")

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "reads the converter's fixture into exactly the rows it converts to" do
    import = configured_import(FIXTURE_DIR.join("money_in_out_fee.csv").read, notes_col_label: "Original Description")

    expected = CSV.read(FIXTURE_DIR.join("money_in_out_fee.converted.csv"), headers: true)

    assert_equal expected.map { |r| [ r["date"], r["name"], r["amount"].to_d, r["notes"].to_s ] },
                 import.rows.ordered.map { |r| [ r.date, r.name, r.amount.to_d, r.notes.to_s ] }
  end

  test "publishes the converter's fixture with money in stored negative and money out positive" do
    import = configured_import(FIXTURE_DIR.join("money_in_out_fee.csv").read, notes_col_label: "Original Description")

    import.publish

    assert import.reload.complete?, import.error
    expected = CSV.read(FIXTURE_DIR.join("money_in_out_fee.converted.csv"), headers: true)
                  .map { |r| [ r["date"], r["name"], -r["amount"].to_d ] }
    assert_equal expected.sort, import.entries.map { |e| [ e.date.to_s, e.name, e.amount ] }.sort
    assert_equal(-5000, import.entries.find_by!(name: "Salary").amount)
    assert_equal 2000, import.entries.find_by!(name: "Rent").amount
    assert_equal 5, import.entries.find_by!(name: "Utilities Fee").amount
  end

  test "a money out line does not take the running balance as its amount" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee,Balance
      2024-01-02,Rent,,2000.00,,500.00
    CSV

    import = configured_import(csv)

    assert_equal [ [ "Rent", -2000 ] ], import.rows.map { |r| [ r.name, r.amount.to_d ] }
  end

  test "a line with both money in and money out becomes an in row then an out row" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-05,Transfer,1000.00,1000.00,
    CSV

    import = configured_import(csv)

    assert_equal [ [ "Transfer", 1000 ], [ "Transfer", -1000 ] ], import.rows.ordered.map { |r| [ r.name, r.amount.to_d ] }
  end

  test "a fee on a money line is its own row named after the line" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-09,Utilities,,150.00,5.00
    CSV

    import = configured_import(csv)

    assert_equal [ [ "Utilities", -150 ], [ "Utilities Fee", -5 ] ], import.rows.ordered.map { |r| [ r.name, r.amount.to_d ] }
  end

  test "a fee only line keeps its description and a fee takes the line's other attributes" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee,Category,Notes
      2024-01-04,Bank Fee,,,-15.00,Fees,monthly
      2024-01-09,Utilities,,150.00,5.00,Bills,electric
    CSV

    import = configured_import(csv, category_col_label: "Category", notes_col_label: "Notes")

    assert_equal [ "Bank Fee", -15 ], [ import.rows.ordered.first.name, import.rows.ordered.first.amount.to_d ]
    assert_equal [ "Utilities Fee", "Bills", "electric", "2024-01-09" ],
                 import.rows.ordered.last.then { |r| [ r.name, r.category, r.notes, r.date ] }
  end

  test "a zero or blank fee adds no row and a line with nothing in it is skipped" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,Zero fee,,10.00,0.00
      2024-01-02,Blank fee,,10.00,
      2024-01-03,Nothing,,,
      2024-01-04,All zero,0.00,0.00,0.00
    CSV

    import = configured_import(csv)

    assert_equal [ "Zero fee", "Blank fee" ], import.rows.ordered.map(&:name)
  end

  test "money out and fee are taken as outflows whatever sign the bank wrote" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,Dash,,-2000.00,-3.00
      2024-01-02,Plain,,2000.00,3.00
    CSV

    import = configured_import(csv)

    assert_equal [ -2000, -3, -2000, -3 ], import.rows.ordered.map { |r| r.amount.to_d }
  end

  test "a negative money in is read as an outflow and its fee is still imported" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,Reversal,-50.00,,2.00
      2024-01-02,Good,50.00,,
    CSV

    import = configured_import(csv)

    assert_equal [ [ "Reversal", -50 ], [ "Reversal Fee", -2 ], [ "Good", 50 ] ], import.rows.ordered.map { |r| [ r.name, r.amount.to_d ] }
    assert_equal [ 50, 2, -50 ], import.rows.ordered.map(&:signed_amount)
  end

  test "an unreadable amount keeps its line as an invalid row instead of dropping it" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,Garbled,,abc,2.00
      2024-01-02,Fine,,10.00,
    CSV

    import = configured_import(csv)

    assert_equal [ "Garbled", "Fine" ], import.rows.ordered.map(&:name)
    assert_not import.rows.ordered.first.valid?
    assert import.rows.ordered.last.valid?
    assert_not import.cleaned?
  end

  test "reads amounts in the import's number format" do
    csv = <<~CSV
      Date;Description;Money In;Money Out;Fee
      2024-01-01;Salary;R 12 345,50;;
      2024-01-02;Rent;;1 234,56;1,50
    CSV

    import = configured_import(csv, col_sep: ";", number_format: "1 234,56")

    assert_equal [ [ "Salary", "12345.50" ], [ "Rent", "-1234.56" ], [ "Rent Fee", "-1.50" ] ],
                 import.rows.ordered.map { |r| [ r.name, r.amount ] }
  end

  test "numbers the rows one by one in file order even when a line yields several" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,A,1.00,2.00,3.00
      2024-01-02,Skipped,,,
      2024-01-03,B,,4.00,5.00
      2024-01-04,C,6.00,,
    CSV

    import = configured_import(csv)

    assert_equal [ 1, 2, 3, 4, 5, 6 ], import.rows.ordered.map(&:source_row_number)
    assert_equal [ "A", "A", "A Fee", "B", "B Fee", "C" ], import.rows.ordered.map(&:name)
    assert_equal 6, import.reload.rows_count
  end

  test "regenerating the rows replaces them" do
    import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,A,,1.00,\n")

    import.generate_rows_from_csv
    import.generate_rows_from_csv

    assert_equal 1, import.rows.count
  end

  test "a file with no readable lines generates no rows" do
    import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,A,,,\n")

    assert_equal 0, import.rows.count
    assert_equal 0, import.rows_count
  end

  test "the same sign comes out whichever sign settings the import had before" do
    csv = <<~CSV
      Date,Description,Money In,Money Out,Fee
      2024-01-01,Salary,100.00,,
      2024-01-02,Rent,,40.00,2.00
    CSV

    [
      { signage_convention: "inflows_positive", amount_type_strategy: "signed_amount" },
      { signage_convention: "inflows_negative", amount_type_strategy: "signed_amount" },
      { signage_convention: "inflows_positive", amount_type_strategy: "custom_column",
        entity_type_col_label: "Description", amount_type_identifier_value: "Salary", amount_type_inflow_value: "inflows_positive" },
      { signage_convention: "inflows_negative", amount_type_strategy: "custom_column",
        entity_type_col_label: "Description", amount_type_identifier_value: "Salary", amount_type_inflow_value: "inflows_negative" }
    ].each do |before|
      import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: csv, **before)
      import.update!(**money_columns, date_format: "%Y-%m-%d")
      import.generate_rows_from_csv

      assert_equal "signed_amount", import.amount_type_strategy, "strategy from #{before}"
      assert_equal "inflows_positive", import.signage_convention, "convention from #{before}"
      assert_equal [ -100, 40, 2 ], import.rows.ordered.map(&:signed_amount), "stored signs from #{before}"
    end
  end

  test "settings are forced even when the sign settings arrive with the money out column" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: "Date,Description,Money In,Money Out,Fee\n")

    import.update!(**money_columns, date_format: "%Y-%m-%d", signage_convention: "inflows_negative", amount_type_strategy: "custom_column")

    assert_equal [ "signed_amount", "inflows_positive" ], [ import.amount_type_strategy, import.signage_convention ]
  end

  test "an import without a money out column keeps the sign settings it was given" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, signage_convention: "inflows_negative")

    import.update!(outflow_col_label: "", date_col_label: "Date")

    assert_equal "inflows_negative", import.signage_convention
  end

  test "importing the same file again publishes no duplicates" do
    csv = FIXTURE_DIR.join("money_in_out_fee.csv").read
    first = configured_import(csv)
    first.publish
    assert first.reload.complete?, first.error
    assert_equal 12, first.entries.count

    second = configured_import(csv)

    assert_no_difference -> { @account.entries.count } do
      second.publish
    end
    assert second.reload.complete?, second.error
  end

  test "a file with no money out column is read exactly as before, balance fallback included" do
    csv = <<~CSV
      Date,Description,Amount,Balance
      2024-01-02,Rent,,500.00
      2024-01-03,Coffee,-5.50,100.00
    CSV
    import = @family.imports.create!(
      type: "TransactionImport", account: @account, raw_file_str: csv, date_format: "%Y-%m-%d",
      date_col_label: "Date", amount_col_label: "Amount", name_col_label: "Description"
    )

    import.generate_rows_from_csv
    ours = row_attributes(import)
    Import.instance_method(:generate_rows_from_csv).bind_call(import)

    assert_equal row_attributes(import), ours
    assert_equal [ "500.00", "-5.50" ], import.rows.ordered.map(&:amount)
  end

  test "a template carries the money out and fee columns to the next import" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete",
                                       date_col_label: "Date", amount_col_label: "Money In", **money_columns)
    fresh = @family.imports.create!(type: "TransactionImport", account: @account, column_mappings: { "other" => "kept" },
                                    raw_file_str: "Date,Description,Money In,Money Out,Fee\n")

    fresh.apply_template!(template)

    assert_equal [ "Money Out", "Fee", "Money In", "kept" ],
                 [ fresh.outflow_col_label, fresh.fee_col_label, fresh.amount_col_label, fresh.column_mappings["other"] ]
    assert_equal [ "signed_amount", "inflows_positive" ], [ fresh.amount_type_strategy, fresh.signage_convention ]
  end

  test "a template is applied without its money columns when the new file does not have them" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete",
                                       date_col_label: "Date", amount_col_label: "Money In", **money_columns)
    fresh = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: "Date,Description,Money In,Debit\n2024-01-01,A,,5.00\n")

    assert_nothing_raised { fresh.apply_template!(template) }

    assert_nil fresh.outflow_col_label
    assert_equal "Money In", fresh.amount_col_label
  end

  test "a template without the columns clears them from the next import" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete", amount_col_label: "Amount")
    fresh = @family.imports.create!(type: "TransactionImport", account: @account, **money_columns)

    fresh.apply_template!(template)

    assert_nil fresh.outflow_col_label
    assert_nil fresh.fee_col_label
  end

  test "a template does not bring its money columns into a Sure export" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete", **money_columns)
    fresh = @family.imports.create!(type: "TransactionImport", account: @account,
                                    raw_file_str: "#{Family::DataExporter::TRANSACTIONS_CSV_HEADERS.join(",")}\n")

    fresh.apply_template!(template)

    assert_nil fresh.outflow_col_label
    assert_equal "inflows_negative", fresh.signage_convention
  end

  test "uploading a Sure export over a money out configuration drops the columns and keeps the export's sign" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, column_mappings: { "other" => "kept" })
    import.update!(**money_columns)
    assert_equal [ "inflows_positive", "Money Out" ], [ import.signage_convention, import.outflow_col_label ]

    import.assign_attributes(raw_file_str: "#{Family::DataExporter::TRANSACTIONS_CSV_HEADERS.join(",")}\n", col_sep: ",")
    import.preset_for_uploaded_csv
    import.save!(validate: false)
    import.update!(rows_to_skip: 0)

    assert_equal "inflows_negative", import.signage_convention
    assert_equal({ "other" => "kept" }, import.column_mappings)
  end

  test "blank column choices remove the keys and keep the other mappings" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, column_mappings: { "other" => "kept" })

    import.update!(outflow_col_label: "Money Out", fee_col_label: "Fee")
    assert_equal({ "other" => "kept", "outflow_col_label" => "Money Out", "fee_col_label" => "Fee" }, import.reload.column_mappings)

    import.update!(outflow_col_label: "", fee_col_label: nil)
    assert_equal({ "other" => "kept" }, import.reload.column_mappings)
  end

  # Cases from the Analyzer's sample_transactions_Format2Parser.csv, the same
  # export shape: Nr, Account, Posting Date, Description, Parent Category,
  # Category, Money In, Money Out, Fee and a running Balance.
  ANALYZER_FORMAT2 = <<~CSV.freeze
    Nr,Account,Posting Date,Transaction Date,Description,Original Description,Parent Category,Category,Money In,Money Out,Fee,Balance
    1,1322219069,2025-03-01,2025-03-01 03:24,Live Better Interest Sweep,LB Interest sweep | FEB 2025,Transfer,Transfer,,-0.80,,1123.66
    8,1322219069,2025-03-13,2025-03-13 16:34,Banking App Immediate Payment: Xolani Maseko,XOLANI MASEKO,Personal & Family,Digital Payments,,-100.00,,44.97
    9,1322219069,2025-03-13,2025-03-13 16:34,Immediate Payment Fee,Immediate Payment Fee,Fees,Fees,,,-1.00,43.97
    10,1322219069,2025-03-30,2025-03-30 10:48,PayShap Payment Received: Mycapitec,MyCapitec,Other Income,Other Income,2500.00,,,2543.97
    12,1322219069,2025-03-31,2025-03-31 23:12,Interest Received,Interest Received,Interest,Interest,0.87,,,2844.84
    13,1322219069,2025-03-31,2025-03-31 23:12,Monthly Account Admin Fee,Monthly Account Admin Fee,Fees,Fees,,,-7.50,2837.34
  CSV

  test "reads the Analyzer's Format 2 export through its Posting Date and Description columns" do
    import = configured_import(ANALYZER_FORMAT2, date_col_label: "Posting Date", category_col_label: "Category")

    assert_equal [
      [ "2025-03-01", "Live Better Interest Sweep", -0.80, "Transfer" ],
      [ "2025-03-13", "Banking App Immediate Payment: Xolani Maseko", -100, "Digital Payments" ],
      [ "2025-03-13", "Immediate Payment Fee", -1, "Fees" ],
      [ "2025-03-30", "PayShap Payment Received: Mycapitec", 2500, "Other Income" ],
      [ "2025-03-31", "Interest Received", 0.87, "Interest" ],
      [ "2025-03-31", "Monthly Account Admin Fee", -7.50, "Fees" ]
    ], import.rows.ordered.map { |r| [ r.date, r.name, r.amount.to_d.to_f, r.category ] }

    import.publish
    assert import.reload.complete?, import.error
    assert_equal [ 0.80, 100, 1, -2500, -0.87, 7.50 ].map(&:to_d).sort, import.entries.map(&:amount).sort
  end

  test "differences from the Analyzer: a negative money in is an outflow, a both-sides line is split, an empty line is skipped" do
    csv = <<~CSV
      Nr,Posting Date,Description,Money In,Money Out,Fee,Balance
      1,2025-03-01,Negative in,-5.00,,,10.00
      2,2025-03-02,Both,5.00,3.00,,10.00
      3,2025-03-03,Empty,,,,10.00
    CSV

    import = configured_import(csv, date_col_label: "Posting Date")

    assert_equal [ [ "Negative in", -5 ], [ "Both", 5 ], [ "Both", -3 ] ], import.rows.ordered.map { |r| [ r.name, r.amount.to_d ] }
  end

  AMBIGUOUS_NOTATIONS = {
    "parentheses" => "(50.00)",
    "unicode minus" => "\u221250.00",
    "en dash" => "\u201350.00",
    "trailing minus" => "50.00-",
    "CR suffix" => "50.00 CR",
    "DR suffix" => "50.00DR",
    "space grouping under 1,234.56" => "1 234,56",
    "European notation under 1,234.56" => "1.234,56",
    "letters" => "12a.00",
    "exponent" => "1e5",
    "bad grouping" => "1,23,456.00",
    "long first group" => "1234,567.00",
    "bare separator" => "50.",
    "double minus" => "--50.00"
  }.freeze

  test "ambiguous or foreign number notation makes the line one invalid row, in any of the three columns" do
    AMBIGUOUS_NOTATIONS.each do |label, cell|
      { "Money In" => [ cell, "", "" ], "Money Out" => [ "", cell, "" ], "Fee" => [ "", "10.00", cell ] }.each do |column, (money_in, money_out, fee)|
        csv = "Date,Description,Money In,Money Out,Fee\n2024-01-01,Line,\"#{money_in}\",\"#{money_out}\",\"#{fee}\"\n"
        import = configured_import(csv)

        assert_equal [ [ "Line", "" ] ], import.rows.map { |r| [ r.name, r.amount.to_s ] }, "#{label} (#{cell.inspect}) in #{column}"
        assert_not import.rows.first.valid?, "#{label} in #{column} must block publishing"
        assert_not import.cleaned?
      end
    end
  end

  # The notation each number_format option means, with a correct value, the
  # amount it stands for, and a value written for a different option.
  NUMBER_NOTATIONS = {
    "1,234.56" => { good: "1,234.56", amount: "1234.56", wrong: [ "1.234,56", "1 234,56", "1,234,56" ] },
    "1.234,56" => { good: "1.234,56", amount: "1234.56", wrong: [ "1,234.56", "1 234,56", "1.234.56" ] },
    "1 234,56" => { good: "1 234,56", amount: "1234.56", wrong: [ "1,234.56", "1.234,56", "1 234.56" ] },
    "1,234" => { good: "1,234", amount: "1234", wrong: [ "1.234", "1,234.56", "12,34" ] }
  }.freeze

  test "every number format option is covered by the notation table" do
    assert_equal Import::NUMBER_FORMATS.keys.sort, NUMBER_NOTATIONS.keys.sort
  end

  test "each number format accepts its own notation and refuses another" do
    NUMBER_NOTATIONS.each do |format, notation|
      quote = ->(cell) { cell.include?(",") || cell.include?(";") ? %("#{cell}") : cell }
      import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Good,#{quote.(notation[:good])},,\n", number_format: format)
      assert_equal [ notation[:amount] ], import.rows.map(&:amount), "#{format} should accept #{notation[:good]}"
      assert import.rows.first.valid?

      notation[:wrong].each do |wrong|
        import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Bad,,#{quote.(wrong)},\n", number_format: format)
        assert_equal [ "" ], import.rows.map { |r| r.amount.to_s }, "#{format} must refuse #{wrong}"
        assert_not import.rows.first.valid?
      end
    end
  end

  test "the space grouped format also takes a non-breaking or narrow no-break space" do
    [ "\u00A0", "\u202F" ].each do |space|
      import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Good,\"1#{space}234,56\",,\n", number_format: "1 234,56")
      assert_equal [ "1234.56" ], import.rows.map(&:amount)
    end
  end

  test "a leading currency symbol or code is tolerated where the format matches" do
    {
      [ "1,234.56", "R1,234.56" ] => "1234.56",
      [ "1,234.56", "R 1,234.56" ] => "1234.56",
      [ "1,234.56", "ZAR 1,234.56" ] => "1234.56",
      [ "1,234.56", "-R1,234.56" ] => "-1234.56",
      [ "1,234.56", "$1,234.56" ] => "1234.56",
      [ "1.234,56", "\u20AC 1.234,56" ] => "1234.56",
      [ "1 234,56", "R 1 234,56" ] => "1234.56"
    }.each do |(format, cell), amount|
      csv = "Date,Description,Money In,Money Out,Fee\n2024-01-01,Line,\"#{cell}\",,\n"
      assert_equal [ amount ], configured_import(csv, number_format: format).rows.map(&:amount), "#{cell} under #{format}"
    end
  end

  test "a currency prefix does not rescue a notation that matches no format" do
    NUMBER_NOTATIONS.each_key do |format|
      import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Line,\"R 1 234.56\",,\n", number_format: format)
      assert_equal [ "" ], import.rows.map { |r| r.amount.to_s }, "R 1 234.56 under #{format}"
    end
  end

  test "an import whose money column is not in the file cannot be valid or generate rows" do
    import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n")
    import.update_column(:raw_file_str, "Date,Description,Money In,Debit,Fee\n2024-01-01,Rent,,10.00,\n")
    stale = TransactionImport.find(import.id)
    row_ids = stale.rows.ids

    stale.outflow_col_label = "Money Out" # the configure form submits it again
    assert_not stale.valid?
    assert_match(/Money Out/, stale.errors.full_messages.to_sentence)

    error = assert_raises(ActiveRecord::RecordInvalid) { stale.generate_rows_from_csv }
    assert_match(/Money Out/, error.message)
    assert_equal row_ids, stale.rows.reload.ids
    assert_equal 1, stale.reload.rows_count
  end

  test "a missing amount or fee column is named too" do
    import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n")
    import.update_column(:raw_file_str, "Date,Description,Credit,Money Out\n2024-01-01,Rent,,10.00\n")

    stale = TransactionImport.find(import.id)

    stale.outflow_col_label = "Money Out"
    assert_not stale.valid?
    assert_match(/Money In/, stale.errors.full_messages.to_sentence)
    assert_match(/Fee/, stale.errors.full_messages.to_sentence)
  end

  test "a file replaced without validation drops the money columns that are not in it" do
    import = configured_import("Date,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n")
    import.assign_attributes(raw_file_str: "Date,Description,Debit\n2024-01-02,Rent,10.00\n")
    import.save!(validate: false)

    reloaded = TransactionImport.find(import.id)

    assert_nil reloaded.outflow_col_label
    assert_nothing_raised { reloaded.update!(amount_col_label: "Debit") }
  end

  test "a fee column needs a money out column" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: "Date,Description,Amount,Fee\n2024-01-01,A,1.00,0.50\n")

    assert_not import.update(fee_col_label: "Fee")
    assert_includes import.errors.full_messages, I18n.t("imports.errors.fee_requires_money_out")
    assert_nil import.reload.fee_col_label
  end

  test "rows are not built from a fee column that has no money out column" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, date_col_label: "Date", amount_col_label: "Amount",
                                     raw_file_str: "Date,Description,Amount,Fee\n2024-01-01,A,1.00,0.50\n", date_format: "%Y-%m-%d")
    import.assign_attributes(fee_col_label: "Fee")

    assert_raises(ActiveRecord::RecordInvalid) { import.generate_rows_from_csv }
  end

  test "the same column cannot serve two money roles" do
    csv = "Date,Description,Money In,Money Out,Fee\n2024-01-01,A,1.00,,\n"
    import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: csv)

    [
      [ { amount_col_label: "Money In", outflow_col_label: "money in" }, "Money In" ],
      [ { amount_col_label: "Money In", outflow_col_label: "Money Out", fee_col_label: "Money In" }, "Money In" ],
      [ { amount_col_label: "Money In", outflow_col_label: "Money Out", fee_col_label: "Money Out" }, "Money Out" ]
    ].each do |attributes, named|
      assert_not import.update(attributes), attributes.inspect
      assert_match(/#{named}.*same column|same column.*#{named}/i, import.errors.full_messages.to_sentence)
      import.reload
    end
  end

  test "lines that split into several rows count every row, and the publish limit counts rows" do
    csv = "Date,Description,Money In,Money Out,Fee\n2024-01-01,A,5.00,5.00,1.00\n"
    import = configured_import(csv)

    assert_equal 3, import.rows_count
    TransactionImport.any_instance.stubs(:max_row_count).returns(2)
    assert_raises(Import::MaxRowCountExceededError) { import.publish_later }
  end

  FILE_WITH_MONEY_COLUMNS = "Date,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n".freeze
  FILE_WITHOUT_MONEY_COLUMNS = "Date,Description,Credit,Debit\n2024-01-02,Rent,,10.00\n".freeze
  PREAMBLE_FILE = "Account statement\nDate,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n".freeze

  test "an unrelated update on an import whose money columns are gone from the file does not raise" do
    import = configured_import(FILE_WITH_MONEY_COLUMNS)
    import.update_column(:raw_file_str, FILE_WITHOUT_MONEY_COLUMNS)
    stale = TransactionImport.find(import.id)

    assert_nothing_raised do
      stale.update!(account: accounts(:credit_card))
      stale.update!(status: "failed")
      stale.update!(status: "importing")
    end
  end

  test "uploading a file without the saved money columns drops them, with or without validation" do
    [ true, false ].each do |validate|
      import = configured_import(FILE_WITH_MONEY_COLUMNS)

      import.assign_attributes(raw_file_str: FILE_WITHOUT_MONEY_COLUMNS)
      import.preset_for_uploaded_csv
      import.save!(validate: validate)

      reloaded = TransactionImport.find(import.id)
      assert_nil reloaded.column_mappings, "validate: #{validate}"
      assert_not reloaded.money_out_column?
    end
  end

  test "dropping the money columns leaves the sign settings as they were, ready to be edited" do
    import = configured_import(FILE_WITH_MONEY_COLUMNS)

    import.update!(raw_file_str: FILE_WITHOUT_MONEY_COLUMNS)

    assert_equal [ "signed_amount", "inflows_positive" ], [ import.amount_type_strategy, import.signage_convention ]
  end

  test "uploading a file that still has the saved money columns keeps them" do
    import = configured_import(FILE_WITH_MONEY_COLUMNS)

    import.assign_attributes(raw_file_str: "Date,Description,Money In,Money Out,Fee\n2024-02-01,Rent,,12.00,1.00\n")
    import.preset_for_uploaded_csv
    import.save!(validate: false)

    assert_equal({ "outflow_col_label" => "Money Out", "fee_col_label" => "Fee" }, TransactionImport.find(import.id).column_mappings)
  end

  test "a file lacking only the fee column drops all the money columns, so they are chosen together again" do
    import = configured_import(FILE_WITH_MONEY_COLUMNS)

    import.update!(raw_file_str: "Date,Description,Money In,Money Out\n2024-02-01,Rent,,12.00\n")

    assert_nil import.reload.column_mappings
  end

  test "changing rows_to_skip so the saved money columns leave the headers saves it and drops them" do
    import = configured_import(PREAMBLE_FILE, rows_to_skip: 1)
    assert import.money_out_column?

    import.update!(rows_to_skip: 0)

    reloaded = TransactionImport.find(import.id)
    assert_equal 0, reloaded.rows_to_skip
    assert_nil reloaded.column_mappings
    assert_equal "Account statement", reloaded.csv_headers.first
  end

  test "changing rows_to_skip keeps the money columns when the new header row still has them" do
    file = "Date,Description,Money In,Money Out,Fee\nDate,Description,Money In,Money Out,Fee\n2024-01-01,Rent,,10.00,\n"
    import = configured_import(file)

    import.update!(rows_to_skip: 1)

    assert_equal 1, import.reload.rows_to_skip
    assert_equal "Money Out", import.outflow_col_label
  end

  test "rows_to_skip and the money columns can change in one save when they fit the new headers" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: PREAMBLE_FILE)

    import.update!(rows_to_skip: 1, **money_columns)

    assert_equal [ 1, "Money Out", "Fee" ], [ import.reload.rows_to_skip, import.outflow_col_label, import.fee_col_label ]
  end

  test "choosing money columns that are not under the new headers in the same save is refused" do
    import = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: PREAMBLE_FILE)

    assert_not import.update(rows_to_skip: 0, **money_columns)
    assert_match(/Money Out/, import.errors.full_messages.to_sentence)
  end

  test "a template from a money out import brings no forced sign into a file without the money columns" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete", date_col_label: "Date", **money_columns)
    assert_equal "inflows_positive", template.signage_convention
    fresh = @family.imports.create!(type: "TransactionImport", account: @account, signage_convention: "inflows_negative", raw_file_str: FILE_WITHOUT_MONEY_COLUMNS)

    fresh.apply_template!(template)

    assert_nil fresh.outflow_col_label
    assert_equal "inflows_negative", fresh.signage_convention
    assert_equal "Date", fresh.date_col_label
  end

  test "a template is judged against the header row its own rows_to_skip gives" do
    template = @family.imports.create!(type: "TransactionImport", account: @account, status: "complete", raw_file_str: PREAMBLE_FILE,
                                       rows_to_skip: 1, date_col_label: "Date", **money_columns)
    fresh = @family.imports.create!(type: "TransactionImport", account: @account, raw_file_str: PREAMBLE_FILE)

    fresh.apply_template!(template)

    assert_equal [ 1, "Money Out" ], [ fresh.reload.rows_to_skip, fresh.outflow_col_label ]
  end

  private
    def money_columns
      { amount_col_label: "Money In", outflow_col_label: "Money Out", fee_col_label: "Fee" }
    end

    def configured_import(csv, **options)
      import = @family.imports.create!(
        type: "TransactionImport", account: @account, raw_file_str: csv,
        date_col_label: "Date", name_col_label: "Description", date_format: "%Y-%m-%d", number_format: "1,234.56",
        **money_columns, **options
      )
      import.generate_rows_from_csv
      import.reload.sync_mappings
      import
    end

    def row_attributes(import)
      import.rows.reload.ordered.map { |r| r.attributes.except("id", "import_id", "created_at", "updated_at") }
    end
end
