require "test_helper"

class Import::ConfigurationsMoneyColumnsTest < ActionDispatch::IntegrationTest
  CSV_TEXT = <<~CSV.freeze
    Date,Description,Money In,Money Out,Fee,Balance
    2024-01-01,Salary,5000.00,,,5000.00
    2024-01-02,Rent,,2000.00,5.00,2995.00
  CSV

  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build
    @import = imports(:transaction)
    @import.update!(raw_file_str: CSV_TEXT, col_sep: ",")
  end

  test "the configure step offers the file's headers for the money out and fee columns" do
    get import_configuration_url(@import)

    assert_response :success
    assert_select "label", text: "Money out column"
    assert_select "label", text: "Fee column"
    # Each select sits in a half-width cell of one row, beside its hint.
    %w[outflow_col_label fee_col_label].each do |field|
      assert_select "div.flex > div.w-1\\/2 select[name='import[#{field}]']"
    end
    %w[outflow_col_label fee_col_label].each do |field|
      assert_select "select[name='import[#{field}]'] option", count: 7 do |options|
        assert_equal [ "", "Date", "Description", "Money In", "Money Out", "Fee", "Balance" ], options.map { |o| o["value"].to_s }
      end
    end
  end

  test "the sign controls stay editable until a money out column is chosen" do
    get import_configuration_url(@import)

    assert_select "select[name='import[amount_type_strategy]']:not([disabled])"
    assert_select "select[name='import[signage_convention]']:not([disabled])"
    assert_select "p", text: I18n.t("import.configurations.transaction_import.sign_set_by_money_out"), count: 0
  end

  test "the sign controls stay editable and are explained once a money out column is saved" do
    @import.update!(outflow_col_label: "Money Out")

    get import_configuration_url(@import)

    assert_select "select[name='import[outflow_col_label]'] option[selected][value='Money Out']"
    assert_select "select[name='import[amount_type_strategy]']:not([disabled])[aria-describedby='money-out-sign-note']"
    assert_select "select[name='import[signage_convention]']:not([disabled])[aria-describedby='money-out-sign-note']"
    assert_select "p#money-out-sign-note", text: "While a money out column is chosen, the two sign options below are set for you and ignored."
  end

  test "the fee hint says a fee is always money out" do
    get import_configuration_url(@import)

    assert_select "p", text: /always money out/
  end

  test "clearing money out with explicit sign values stores exactly those values" do
    @import.update!(outflow_col_label: "Money Out")
    assert_equal "inflows_positive", @import.signage_convention

    patch import_configuration_url(@import), params: {
      import: configuration_params(outflow_col_label: "", fee_col_label: "", amount_type_strategy: "signed_amount", signage_convention: "inflows_negative")
    }

    @import.reload
    assert_equal [ "signed_amount", "inflows_negative" ], [ @import.amount_type_strategy, @import.signage_convention ]
    assert_nil @import.column_mappings
  end

  test "keeping a money out column forces the sign values whatever the form sends" do
    @import.update!(outflow_col_label: "Money Out")

    patch import_configuration_url(@import), params: {
      import: configuration_params(amount_type_strategy: "custom_column", signage_convention: "inflows_negative",
                                   entity_type_col_label: "Description", amount_type_identifier_value: "Salary", amount_type_inflow_value: "inflows_negative")
    }

    @import.reload
    assert_equal [ "signed_amount", "inflows_positive" ], [ @import.amount_type_strategy, @import.signage_convention ]
  end

  test "a fee column without a money out column is refused with a message and nothing is stored" do
    patch import_configuration_url(@import), params: { import: configuration_params(outflow_col_label: "") }

    assert_redirected_to import_configuration_url(@import)
    assert_equal I18n.t("imports.errors.fee_requires_money_out"), flash[:alert]
    assert_nil @import.reload.column_mappings
    assert_nil @import.amount_col_label

    follow_redirect!
    assert_select "*", text: /Choose a money out column to use a fee column/
  end

  test "choosing one column for two roles is refused naming the clash" do
    patch import_configuration_url(@import), params: { import: configuration_params(outflow_col_label: "Money In", fee_col_label: "") }

    assert_match(/same column \(Money In\)/, flash[:alert])
    assert_nil @import.reload.column_mappings
  end

  test "a money column the file does not have is refused naming it" do
    row_ids = @import.rows.ids

    patch import_configuration_url(@import), params: { import: configuration_params(outflow_col_label: "Debit", fee_col_label: "") }

    assert_match(/"Debit"/, flash[:alert])
    assert_nil @import.reload.column_mappings
    assert_equal row_ids, @import.rows.reload.ids
  end

  test "after a different file replaces the statement the old label shows as not used and can be cleared" do
    @import.update!(outflow_col_label: "Money Out", fee_col_label: "Fee", amount_col_label: "Money In", date_col_label: "Date", date_format: "%Y-%m-%d")
    @import.generate_rows_from_csv
    @import.assign_attributes(raw_file_str: "Date,Description,Credit,Debit\n2024-01-02,Rent,,10.00\n")
    @import.save!(validate: false)

    get import_configuration_url(@import)
    assert_response :success
    assert_select "select[name='import[outflow_col_label]'] option[selected]", count: 0

    patch import_configuration_url(@import), params: {
      import: configuration_params(amount_col_label: "Credit", outflow_col_label: "Debit", fee_col_label: "")
    }

    assert_redirected_to import_clean_url(@import)
    assert_equal({ "outflow_col_label" => "Debit" }, @import.reload.column_mappings)
    assert_equal [ [ "Rent", 10 ] ], @import.rows.map { |r| [ r.name, r.signed_amount ] }
  end

  test "an unreadable amount shows on the clean step as an invalid row that blocks the next step" do
    patch import_configuration_url(@import), params: { import: configuration_params(fee_col_label: "").merge(number_format: "1.234,56") }

    get import_clean_url(@import)

    assert_response :success
    assert_select "*", text: /Amount is required|is required/
    assert_not @import.reload.cleaned?
  end

  test "changing only the account keeps the forced sign settings of a money out import" do
    @import.update!(outflow_col_label: "Money Out", amount_col_label: "Money In")
    @import.update_columns(signage_convention: "inflows_negative", amount_type_strategy: "custom_column")

    patch import_url(@import), params: { import: { account_id: accounts(:depository).id } }

    @import.reload
    assert_equal accounts(:depository), @import.account
    assert_equal [ "signed_amount", "inflows_positive" ], [ @import.amount_type_strategy, @import.signage_convention ]
  end

  test "saving stores the labels, forces the sign settings and builds the rows" do
    @import.update!(signage_convention: "inflows_negative")

    patch import_configuration_url(@import), params: { import: configuration_params }

    assert_redirected_to import_clean_url(@import)
    @import.reload
    assert_equal({ "outflow_col_label" => "Money Out", "fee_col_label" => "Fee" }, @import.column_mappings)
    assert_equal [ "signed_amount", "inflows_positive" ], [ @import.amount_type_strategy, @import.signage_convention ]
    assert_equal [ [ "Salary", -5000 ], [ "Rent", 2000 ], [ "Rent Fee", 5 ] ],
                 @import.rows.ordered.map { |r| [ r.name, r.signed_amount ] }
  end

  test "a blank choice clears a label and the other column mappings survive" do
    @import.update!(column_mappings: { "other" => "kept", "outflow_col_label" => "Money Out", "fee_col_label" => "Fee" })

    patch import_configuration_url(@import), params: { import: configuration_params(outflow_col_label: "Money Out", fee_col_label: "") }

    assert_equal({ "other" => "kept", "outflow_col_label" => "Money Out" }, @import.reload.column_mappings)

    patch import_configuration_url(@import), params: { import: configuration_params(outflow_col_label: "", fee_col_label: "") }

    assert_equal({ "other" => "kept" }, @import.reload.column_mappings)
  end

  test "an import type without these columns ignores them" do
    trade = users(:family_admin).family.imports.create!(type: "TradeImport", raw_file_str: CSV_TEXT, col_sep: ",")

    assert_nothing_raised do
      patch import_configuration_url(trade), params: { import: { date_col_label: "Date", date_format: "%Y-%m-%d", outflow_col_label: "Money Out" } }
    end

    assert_nil trade.reload.column_mappings
  end

  test "uploading a file without the saved money columns drops them and the configure page says not used" do
    @import.update!(outflow_col_label: "Money Out", fee_col_label: "Fee", amount_col_label: "Money In", date_col_label: "Date", date_format: "%Y-%m-%d")
    @import.generate_rows_from_csv

    patch import_upload_url(@import), params: { import: { raw_file_str: "Date,Description,Credit,Debit\n2024-01-02,Rent,,10.00\n", col_sep: "," } }

    assert_nil @import.reload.column_mappings
    get import_configuration_url(@import)
    assert_response :success
    assert_select "select[name='import[outflow_col_label]'] option[selected]", count: 0
    assert_select "p#money-out-sign-note", count: 0
    assert_select "select[name='import[amount_type_strategy]']:not([disabled])"
    assert_select "select[name='import[signage_convention]']:not([disabled])"
  end

  test "uploading next month's file with the same columns keeps them selected" do
    @import.update!(outflow_col_label: "Money Out", fee_col_label: "Fee", amount_col_label: "Money In")

    patch import_upload_url(@import), params: { import: { raw_file_str: "Date,Description,Money In,Money Out,Fee\n2024-02-01,Rent,,10.00,\n", col_sep: "," } }

    get import_configuration_url(@import)
    assert_select "select[name='import[outflow_col_label]'] option[selected][value='Money Out']"
    assert_select "select[name='import[fee_col_label]'] option[selected][value='Fee']"
  end

  test "when the file no longer has the saved money columns the account can still be changed" do
    stale_money_import

    patch import_url(@import), params: { import: { account_id: accounts(:credit_card).id } }

    assert_redirected_to import_url(@import)
    assert_equal accounts(:credit_card), @import.reload.account
  end

  # The rows are still the ones made from the earlier file, as for any import
  # whose file is replaced; publishing them is what the base flow does too.
  test "when the file no longer has the saved money columns publishing does not fail" do
    stale_money_import

    assert_enqueued_with(job: ImportJob) { post publish_import_url(@import) }

    assert_redirected_to import_url(@import)
    assert_equal "importing", @import.reload.status
  end

  test "refreshing rows_to_skip so the saved money columns disappear saves it and shows the new headers" do
    @import.update!(raw_file_str: "Account statement\n#{CSV_TEXT}", rows_to_skip: 1, outflow_col_label: "Money Out", amount_col_label: "Money In")

    patch import_configuration_url(@import), params: { refresh_only: true, import: { rows_to_skip: 0 } }

    assert_redirected_to import_configuration_url(@import)
    assert_equal 0, @import.reload.rows_to_skip
    assert_nil @import.column_mappings

    get import_configuration_url(@import)
    assert_response :success
    assert_select "select[name='import[outflow_col_label]'] option", text: "Account statement"
  end

  test "refreshing rows_to_skip keeps the money columns when they are still in the headers" do
    @import.update!(raw_file_str: "#{CSV_TEXT.lines.first}#{CSV_TEXT}", outflow_col_label: "Money Out", amount_col_label: "Money In")

    patch import_configuration_url(@import), params: { refresh_only: true, import: { rows_to_skip: 1 } }

    assert_equal 1, @import.reload.rows_to_skip
    assert_equal "Money Out", @import.outflow_col_label
  end

  private
    # Rows built from a money out configuration, then the file replaced by one
    # without those columns, bypassing the upload hook.
    def stale_money_import
      @import.update!(account: accounts(:depository), outflow_col_label: "Money Out", fee_col_label: "Fee", amount_col_label: "Money In",
                      date_col_label: "Date", date_format: "%Y-%m-%d")
      @import.generate_rows_from_csv
      @import.reload.sync_mappings
      @import.update_column(:raw_file_str, "Date,Description,Credit,Debit\n2024-01-02,Rent,,10.00\n")
    end

    def configuration_params(**overrides)
      {
        date_col_label: "Date", date_format: "%Y-%m-%d", name_col_label: "Description",
        amount_col_label: "Money In", number_format: "1,234.56",
        outflow_col_label: "Money Out", fee_col_label: "Fee"
      }.merge(overrides)
    end
end
