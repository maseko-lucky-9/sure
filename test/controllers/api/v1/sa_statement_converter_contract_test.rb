# frozen_string_literal: true

require "test_helper"

# Pins what tools/sa-statement-converter relies on in the import API: the
# request its `push` sends, and the reply fields it reads. The CSV is the
# converter's own output for its fixture (its test suite checks the bytes).
class Api::V1::SaStatementConverterContractTest < ActionDispatch::IntegrationTest
  CONVERTED = Rails.root.join("tools/sa-statement-converter/fixtures/money_in_out_fee.converted.csv")

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(user: @user, name: "Converter", scopes: [ "read_write" ],
                              display_key: "test_rw_#{SecureRandom.hex(8)}", source: "web")
    Redis.new.del("api_rate_limit:#{@api_key.id}")

    @csv = CONVERTED.read
    @rows = CSV.parse(@csv, headers: true)
  end

  # The body of `push` in convert.ts.
  def request_body
    {
      type: "TransactionImport", account_id: @account.id, raw_file_content: @csv,
      date_col_label: "date", amount_col_label: "amount", name_col_label: "name", notes_col_label: "notes",
      date_format: "%Y-%m-%d", number_format: "1,234.56", signage_convention: "inflows_positive"
    }
  end

  test "the dry run reports the row count where the converter reads it" do
    assert_no_difference([ "Import.count", "Import::Row.count" ]) do
      post preflight_api_v1_imports_url, params: request_body, headers: api_headers(@api_key), as: :json
    end

    assert_response :success
    data = JSON.parse(response.body).fetch("data")

    assert_equal @rows.size, data.fetch("stats").fetch("rows_count")
    assert_equal true, data.fetch("valid")
    assert_empty data.fetch("errors")
    assert_not data.key?("parsed_rows_count")
  end

  test "a published push imports every row with the converter's signs" do
    entries = @account.entries.where(entryable_type: "Transaction")
    before = entries.count

    perform_enqueued_jobs do
      post api_v1_imports_url, params: request_body.merge(publish: "true"), headers: api_headers(@api_key), as: :json
    end

    assert_response :created
    import = Import.find(JSON.parse(response.body).fetch("data").fetch("id"))
    assert_equal "complete", import.reload.status
    assert_equal @rows.size, entries.count - before

    # The converter writes money in as positive; Sure stores it as negative.
    # Compared as whole lists: one statement line can become two rows with the
    # same date and name (money in and money out).
    sent = @rows.map { |row| [ row["date"], row["name"], -BigDecimal(row["amount"]) ] }
    imported = import.entries.map { |entry| [ entry.date.iso8601, entry.name, entry.amount ] }
    assert_equal sent.sort, imported.sort
  end
end
