# Rough purchasing-power multiplier for thresholds written in dollar-scale
# units ("flag fees of 10 or more"), keyed by ISO code. Currencies not listed
# use 1, so scaling is a strict no-op for them.
#
# Multipliers are Integers: a Float or BigDecimal would change the JSON type of
# stored insight metadata and resurface every card. They are static, not
# exchange-rate based: nightly jobs run offline, and a drifting rate would
# change dedup keys. Add other currencies here.
module Money::Scale
  MULTIPLIERS = { "ZAR" => 20 }.freeze

  def self.for(currency)
    code = currency.respond_to?(:iso_code) ? currency.iso_code : currency
    MULTIPLIERS.fetch(code.to_s.upcase, 1)
  end

  def self.scale(amount, currency)
    amount * self.for(currency)
  end

  # An Arel condition for rows whose `amount` is at least `threshold` scaled to
  # the row's own `currency`, for tables that mix currencies.
  def self.at_least(table, threshold)
    unscaled = table[:currency].not_in(MULTIPLIERS.keys).and(table[:amount].gteq(threshold))

    MULTIPLIERS.reduce(unscaled) do |condition, (code, multiplier)|
      condition.or(table[:currency].eq(code).and(table[:amount].gteq(threshold * multiplier)))
    end
  end
end
