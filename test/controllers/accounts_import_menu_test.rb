require "test_helper"

# The account page's menu starts an import bound to that account: it has to
# make the POST that creates one, not a GET of the import list.
class AccountsImportMenuTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build
  end

  test "the transactions menu item creates a transaction import for the account" do
    account = accounts(:depository)

    get account_url(account)
    request = menu_item_request(I18n.t("accounts.show.menu.import_transactions"))

    assert_difference -> { Import.count }, 1 do
      post request[:path], params: request[:params]
    end

    import = Import.order(:created_at).last
    assert_equal [ "TransactionImport", account ], [ import.type, import.account ]
    assert_redirected_to import_upload_url(import)
  end

  test "the trades menu item creates a trade import for the account" do
    account = accounts(:investment)

    get account_url(account)
    request = menu_item_request(I18n.t("accounts.show.menu.import_trades"))

    assert_difference -> { Import.count }, 1 do
      post request[:path], params: request[:params]
    end

    import = Import.order(:created_at).last
    assert_equal [ "TradeImport", account ], [ import.type, import.account ]
    assert_redirected_to import_upload_url(import)
  end

  test "a user who can only read the account is not offered the import item" do
    sign_in users(:family_member)

    get account_url(accounts(:credit_card))

    assert_response :success
    assert_select "form", text: /#{Regexp.escape(I18n.t("accounts.show.menu.import_transactions"))}/, count: 0
  end

  test "an import requested for an account the user cannot see is created for no account" do
    sign_in users(:family_member)

    assert_difference -> { Import.count }, 1 do
      post imports_url, params: { import: { type: "TransactionImport", account_id: accounts(:investment).id } }
    end

    assert_nil Import.order(:created_at).last.account
  end

  test "an import requested for a read only account is bound to it but cannot be published" do
    sign_in users(:family_member)
    account = accounts(:credit_card)

    post imports_url, params: { import: { type: "TransactionImport", account_id: account.id } }

    import = Import.order(:created_at).last
    assert_equal account, import.account

    TransactionImport.any_instance.expects(:publish_later).never
    post publish_import_url(import)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  private
    # The form a menu item renders: its action and the fields it submits.
    def menu_item_request(text)
      form = css_select("form").find { |f| f.text.include?(text) }
      assert form, "no menu item #{text.inspect} renders a form"
      assert_equal "post", form["method"].to_s.downcase

      fields = form.css("input[name]").reject { |i| %w[authenticity_token _method].include?(i["name"]) }
      { path: form["action"], params: Rack::Utils.parse_nested_query(fields.map { |i| "#{CGI.escape(i["name"])}=#{CGI.escape(i["value"].to_s)}" }.join("&")) }
    end
end
