require "test_helper"

class Money::ScaleTest < ActiveSupport::TestCase
  test "currencies without an entry keep a multiplier of 1" do
    [ "USD", "EUR", "XXX", nil, Money::Currency.new("usd") ].each do |currency|
      assert_instance_of Integer, Money::Scale.for(currency)
      assert_equal 1, Money::Scale.for(currency)
    end
  end

  test "ZAR scales by 20 however it is given" do
    [ "ZAR", "zar", :ZAR, Money::Currency.new("zar") ].each do |currency|
      assert_instance_of Integer, Money::Scale.for(currency)
      assert_equal 20, Money::Scale.for(currency)
    end
  end

  test "scaling an Integer returns an Integer" do
    assert_instance_of Integer, Money::Scale.scale(250, "ZAR")
    assert_equal 5_000, Money::Scale.scale(250, "ZAR")
    assert_instance_of Integer, Money::Scale.scale(250, "USD")
    assert_equal 250, Money::Scale.scale(250, "USD")
  end

  test "at_least compares each row with the threshold in its own currency" do
    sql = Entry.where(Money::Scale.at_least(Entry.arel_table, 100)).to_sql

    assert_match(/"entries"."currency" NOT IN \('ZAR'\) AND "entries"."amount" >= 100/, sql)
    assert_match(/"entries"."currency" = 'ZAR' AND "entries"."amount" >= 2000/, sql)
  end
end
