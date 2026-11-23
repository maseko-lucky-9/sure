# frozen_string_literal: true

require "test_helper"

# The API has no import update action and does not take the web-only Money Out
# and Fee columns: a client that sends them gets a plain single-amount import.
class Api::V1::ImportsMoneyColumnsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user, name: "Money columns key", scopes: [ "read_write" ],
      display_key: "test_mc_#{SecureRandom.hex(8)}", source: "web"
    )
    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "money out and fee labels sent to the API are not stored and the sign settings stay as sent" do
    post api_v1_imports_url,
         params: {
           raw_file_content: "date,amount,name,debit,fee\n2024-01-01,10.00,Test,5.00,1.00\n",
           date_col_label: "date", amount_col_label: "amount", name_col_label: "name",
           outflow_col_label: "debit", fee_col_label: "fee",
           signage_convention: "inflows_negative", account_id: accounts(:depository).id
         },
         headers: { "X-Api-Key" => @api_key.plain_key }

    assert_response :created
    import = Import.find(JSON.parse(response.body).dig("data", "id"))
    assert_nil import.column_mappings
    assert_equal "inflows_negative", import.signage_convention
    assert_equal [ "10.0" ], import.rows.map { |r| r.amount.to_d.to_s }
  end

  test "there is no API route to update an import" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/api/v1/imports/#{imports(:transaction).id}", method: :patch)
    end
  end
end
