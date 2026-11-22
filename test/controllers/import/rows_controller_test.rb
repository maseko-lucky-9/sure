require "test_helper"

class Import::RowsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)

    @import = imports(:transaction)
    @row = import_rows(:one)
  end

  test "show transaction row" do
    get import_row_path(@import, @row)

    assert_row_fields(@row, [ :date, :name, :amount, :currency, :category, :tags, :account, :notes ])

    assert_response :success
  end

  test "show trade row" do
    import = @user.family.imports.create!(type: "TradeImport")
    row = import.rows.create!(source_row_number: 1, date: "01/01/2024", currency: "USD", qty: 10, price: 100, ticker: "AAPL")

    get import_row_path(import, row)

    assert_row_fields(row, [ :date, :ticker, :qty, :price, :currency, :account, :name, :account ])

    assert_response :success
  end

  test "show account row" do
    import = @user.family.imports.create!(type: "AccountImport")
    row = import.rows.create!(source_row_number: 1, name: "Test Account", amount: 10000, currency: "USD")

    get import_row_path(import, row)

    assert_row_fields(row, [ :entity_type, :name, :amount, :currency ])

    assert_response :success
  end

  test "show mint row" do
    import = @user.family.imports.create!(type: "MintImport")
    row = import.rows.create!(source_row_number: 1, date: "01/01/2024", amount: 100, currency: "USD")

    get import_row_path(import, row)

    assert_row_fields(row, [ :date, :name, :amount, :currency, :category, :tags, :account, :notes ])

    assert_response :success
  end

  test "update" do
    patch import_row_path(@import, @row), params: {
      import_row: {
        account: "Checking Account",
        date: "2024-01-01",
        qty: nil,
        ticker: nil,
        price: nil,
        amount: 100,
        currency: "USD",
        name: "Test",
        category: "Food",
        tags: "grocery, dinner",
        entity_type: nil,
        notes: "Weekly shopping"
      }
    }

    assert_redirected_to import_row_path(@import, @row)
  end


  test "member without access to the import's account cannot view or edit its rows" do
    @import.update!(account: accounts(:investment))
    sign_in users(:family_member)

    get import_row_path(@import, @row)
    assert_response :not_found

    assert_no_changes -> { @row.reload.amount } do
      patch import_row_path(@import, @row), params: { import_row: { amount: "999" } }
    end
    assert_response :not_found
  end

  test "rows are closed to a member who cannot view the statement the import was read from" do
    Import.any_instance.stubs(:account_statement).returns(stub(viewable_by?: false))

    get import_row_path(@import, @row)

    assert_response :not_found
  end

  test "member the import's account is shared with can view its rows" do
    @import.update!(account: accounts(:credit_card))
    sign_in users(:family_member)

    get import_row_path(@import, @row)

    assert_response :success
  end

  private
    def assert_row_fields(row, fields)
      fields.each do |field|
        assert_select "turbo-frame##{dom_id(row, field)}"
      end
    end
end
