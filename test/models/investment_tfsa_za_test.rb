require "test_helper"

class InvestmentTfsaZaTest < ActiveSupport::TestCase
  test "the South African tax-free subtype is tax exempt" do
    assert_equal :tax_exempt, Investment.new(subtype: "tfsa_za").tax_treatment
    assert_equal "za", Investment::SUBTYPES.dig("tfsa_za", :region)
  end

  test "the Canadian TFSA is unchanged" do
    assert_equal "ca", Investment::SUBTYPES.dig("tfsa", :region)
    assert_equal :tax_exempt, Investment.new(subtype: "tfsa").tax_treatment
  end

  test "a rand family's subtype select lists South Africa first with the new key" do
    first_group = Investment.subtypes_grouped_for_select(currency: "ZAR").first

    assert_equal I18n.t("accounts.subtype_regions.za"), first_group.first
    assert_equal "South Africa", first_group.first
    assert_includes first_group.last.map(&:last), "tfsa_za"
  end

  test "other currencies still list South Africa after their own regions" do
    labels = Investment.subtypes_grouped_for_select(currency: "USD").map(&:first)

    assert_equal I18n.t("accounts.subtype_regions.us"), labels.first
    assert_includes labels, "South Africa"
  end
end
