require "test_helper"

# tools/sa-merchant-rules/rules.csv is a data file for Sure's rule import. These tests load it the way
# a user's import does and run the rules the way a sync does (ApplyRulesJob), so they cover the
# shipped file and not a copy of its patterns.
class SaMerchantRulesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  CSV_PATH = Rails.root.join("tools/sa-merchant-rules/rules.csv")

  # Rule name => category, in the order the file lists them. The order is the run order.
  EXPECTED_RULES = {
    "SA merchants: Income" => "Income",
    "SA merchants: Healthcare" => "Healthcare",
    "SA merchants: Savings & Investments" => "Savings & Investments",
    "SA merchants: Insurance" => "Insurance",
    "SA merchants: Groceries" => "Groceries",
    "SA merchants: Food & Drink" => "Food & Drink",
    "SA merchants: Food & Drink (more)" => "Food & Drink",
    "SA merchants: Transportation" => "Transportation",
    "SA merchants: Shopping" => "Shopping",
    "SA merchants: Home Improvement" => "Home Improvement",
    "SA merchants: Fees" => "Fees",
    "SA merchants: Fees (more)" => "Fees",
    "SA merchants: Utilities" => "Utilities",
    "SA merchants: Utilities (telecoms)" => "Utilities",
    "SA merchants: Entertainment" => "Entertainment",
    "SA merchants: Mortgage / Rent" => "Mortgage / Rent",
    "SA merchants: Loan Payments" => "Loan Payments",
    "SA merchants: Taxes" => "Taxes"
  }.freeze

  # Keywords that another rule's pattern also matches, on purpose: the rule listed first is above the
  # other in the file and wins. [rule that owns the keyword, keyword, rule that also matches it].
  ORDER_DEPENDENT_OVERLAPS = [
    [ "SA merchants: Healthcare", 'momentum\s+health', "SA merchants: Insurance" ],
    [ "SA merchants: Savings & Investments", 'old\s+mutual\s+invest\w*', "SA merchants: Insurance" ],
    [ "SA merchants: Savings & Investments", 'sanlam\s+invest\w*', "SA merchants: Insurance" ],
    [ "SA merchants: Food & Drink", 'uber\s*\*?\s*eats', "SA merchants: Transportation" ]
  ].freeze

  # Statement description => category. All are outflows (positive amounts in Sure) except Income.
  OUTFLOW_EXAMPLES = {
    "Groceries" => [
      "POS PURCHASE (EFFEC 14012025) Checkers JOHAN CARD NO. 4066", "CHECKERS SIXTY60 SANDTON",
      "PICK N PAY SANDTON CITY", "PICKNPAY EXPRESS FERNDALE", "PICK NPAY ROSEBANK", "PNP CRESTA",
      "WOOLWORTHS FOOD MELROSE ARCH", "WOOLIES SANDTON", "SHOPRITE HILLBROW", "SPAR TOPS RIVONIA",
      "SUPERSPAR ROSEBANK", "KWIKSPAR BRYANSTON", "FOOD LOVERS MARKET FOURWAYS", "MAKRO WOODMEAD",
      "USAVE SOWETO", "BOXER SUPERSTORES SOWETO"
    ],
    "Food & Drink" => [
      "POS PURCHASE (EFFEC 14012025) Cafe Cambista SANDTON CARD NO. 4066", "Cafecambista Sandton (Card 2807)",
      "POS PURCHASE (EFFEC 14012025) Mugg & Bean SANDTON CARD NO. 4066", "MUGG AND BEAN MELROSE", "STEERS ROSEBANK",
      "NANDOS ILLOVO", "NANDO'S SANDTON", "KFC BRYANSTON", "MCDONALDS RIVONIA", "MCDONALD'S RIVONIA",
      "DEBONAIRS PIZZA FOURWAYS", "ROMANS PIZZA SANDTON", "STARBUCKS SANDTON CITY", "VIDA E CAFFE SANDTON",
      "VIDA E CAFFÈ MELROSE", "RESTAURANT BILL", "COFFEE SHOP SANDTON", "UBER *EATS HELP.UBER.COM", "UBER EATS",
      "MR D FOOD", "MRD FOOD", "MRDFOOD JHB", "WIMPY RANDBURG", "SPUR STEAK RANCH BRYANSTON",
      "OCEAN BASKET SANDTON", "CHICKEN LICKEN SOWETO", "BURGER KING FOURWAYS"
    ],
    "Transportation" => [
      "UBER TRIP HELP.UBER.COM", "ENGEN FERNDALE", "POS PURCHASE TOTALENERGIES FERNDALE", "TOTAL FILLPOINT SANDTON",
      "SHELL ULTRA CITY N1", "BP RANDBURG", "SASOL RIVONIA", "CALTEX ROSEBANK", "BOLT.EU/O/2501 TALLINN",
      "BOLT RIDE JOHANNESBURG", "GAUTRAIN SANDTON", "PETROL STATION", "FUEL PURCHASE", "PARKING SANDTON CITY",
      "E-TOLL SANRAL", "ASTRON ENERGY MIDRAND", "PUMA ENERGY FOURWAYS"
    ],
    "Shopping" => [
      "TAKEALOT.COM", "MR PRICE SANDTON", "MRPRICE", "PEP STORES SOWETO", "PEP STORE SOWETO", "EDGARS ROSEBANK",
      "ACKERMANS MIDRAND", "GAME STORE ROSEBANK"
    ],
    "Home Improvement" => [ "BUILDERS WAREHOUSE STRYDOM PARK", "BUILDERS EXPRESS", "LEROY MERLIN", "CASHBUILD" ],
    "Fees" => [
      "TRANSACTION CHARGE", "ADMIN CHARGE", "MONTHLY ACC FEE", "MONTHLY ACCOUNT FEE", "SERVICE FEE",
      "BANK CHARGES", "POS TRAN FEE", "CASH WITHDRAWAL FEE", "DECL POS PURCHASE", "UNPAID FEE",
      "MANAGEMENT FEE", "NOTIFICATION FEE", "CASH DEPOSIT FEE"
    ],
    "Savings & Investments" => [
      "ALLAN GRAY DEBIT ORDER", "CORONATION FUND MANAGERS", "SATRIX 40", "EASYEQUITIES DEPOSIT", "EASY EQUITIES",
      "SYGNIA", "NINETY ONE", "UNIT TRUST DEBIT ORDER", "TFSA CONTRIBUTION", "STANLIB", "OLD MUTUAL INVEST",
      "SANLAM INVESTMENTS"
    ],
    "Utilities" => [
      "ESKOM PREPAID", "PREPAID ELECTRICITY", "CITY POWER JOHANNESBURG", "JOBURG WATER",
      "CITY OF JOHANNESBURG MUNICIPALITY", "RATES AND TAXES", "RATES & TAXES", "WATER AND LIGHTS",
      "VODACOM SP DEBIT ORDER", "MTN PREPAID", "TELKOM DEBIT ORDER", "CELL C AIRTIME", "RAIN 5G DEBIT ORDER",
      "AFRIHOST", "AIRTIME TOPUP", "DATA BUNDLES", "FIBRE", "MWEB", "VUMATEL", "OPENSERVE", "WEBAFRICA"
    ],
    "Healthcare" => [
      "CLICKS PHARMACY SANDTON", "DIS-CHEM RIVONIA", "DISCHEM RIVONIA", "PHARMACY", "MEDICAL", "DOCTORS ROOMS",
      "DENTIST", "HOSPITAL", "NETCARE", "MEDICLINIC", "DISCOVERY HEALTH MEDICAL SCHEME", "DISCOVERY MEDICAL SCHEME",
      "MOMENTUM HEALTH", "BONITAS", "MEDIHELP", "FEDHEALTH", "BESTMED"
    ],
    "Insurance" => [
      "DISCOVERY INSURE", "DISCOVERY LIFE PREMIUM", "DISCOVERY VITALITY", "OUTSURANCE", "MOMENTUM", "SANLAM",
      "OLD MUTUAL", "MIWAY", "KING PRICE", "INSURANCE PREMIUM"
    ],
    "Entertainment" => [
      "NETFLIX.COM", "SPOTIFY P1A2B3", "SPOTIFY PREMIUM", "SHOWMAX", "DSTV", "MULTICHOICE", "YOUTUBE",
      "PLAYSTATION NETWORK", "XBOX", "STEAMGAMES.COM 4259522", "STEAM PURCHASE", "STER KINEKOR", "NU METRO"
    ],
    "Mortgage / Rent" => [
      "RENT PAYMENT", "PAYMENT TO LANDLORD", "HOME LOAN DEBIT ORDER", "BOND REPAYMENT", "BOND PAYMENT"
    ],
    "Loan Payments" => [ "CAR LOAN DEBIT", "VEHICLE FINANCE INSTALMENT", "WESBANK DEBIT ORDER" ],
    "Taxes" => [ "SARS EFILING", "SARS PAYMENT" ]
  }.freeze

  INFLOW_EXAMPLES = [
    "ACB CREDIT CAPITEC Capitec Salary", "SALARY ACME (PTY) LTD", "WAGES", "PAYROLL", "INTEREST RECEIVED", "DIVIDEND"
  ].freeze

  # An employer or fund named like a merchant: money in is income, money out is the merchant's category.
  EMPLOYER_LINES = {
    "SALARY SHOPRITE HOLDINGS" => "Groceries",
    "ACB CREDIT OLD MUTUAL SALARY" => "Insurance",
    "SALARY SANLAM" => "Insurance",
    "SALARY CLICKS" => "Healthcare",
    "SATRIX DIVIDEND" => "Savings & Investments"
  }.freeze

  # Descriptions the substring matching of the source list got wrong, plus words that are left out or
  # narrowed because they are too loose to trust.
  MISFIRES = [
    "SPARKLE CLEANERS", "TRANSPARENT BLINDS", "SPARE PARTS CC", "TRAINING FEE", "RAINBOW PLUMBING",
    "CAR THEFT COVER", "PIRATES FC TICKETS", "SHELLEY BEACH CURIO", "ROMANTIC GETAWAY", "STEAMERS",
    "CURRENT ACCOUNT FEE", "SUBTOTAL ADJUSTMENT", "TOTAL DUE", "POS PURCHASE TOTALSPORTS SANDTON CARD NO. 4066",
    "REFUND FROM THE BANK", "RATES REVIEW", "MRS DLAMINI", "DISCOVERY BANK", "DISCOVERY CARD PAYMENT",
    "WOOLWORTHS FINANCIAL SERVICES", "WOOLWORTHS SANDTON", "BOLT HARDWARE", "MUNICIPAL FINE",
    "PEPPER TREE CAFE", "EDGARSTOWN BAKERY", "SARSFIELD ROAD", "GEMS EDUCATION FEES"
  ].freeze

  setup do
    @family = families(:empty)
    @family.categories.bootstrap!
    @account = @family.accounts.create!(name: "SA test", balance: 1000, currency: "USD", accountable: Depository.new)
    @categories_before_import = @family.categories.count
    import_rules
  end

  test "imports the rules in file order without creating categories" do
    assert_equal EXPECTED_RULES.keys, @family.rules.ordered.pluck(:name)
    assert_equal EXPECTED_RULES.values, @family.rules.ordered.map { |rule| rule.actions.sole.value_display }
    assert @family.rules.all?(&:active)
    assert_equal @categories_before_import, @family.categories.count

    @family.rules.each do |rule|
      assert_equal "set_transaction_category", rule.actions.sole.action_type
      assert_includes @family.categories.ids, rule.actions.sole.value, "#{rule.name} points at a category outside the defaults"
    end
  end

  test "every pattern is a whole-word alternation the rule engine accepts" do
    @family.rules.each do |rule|
      pattern = name_pattern(rule)

      assert_nil Rule::SafeRegex.error_for(pattern), "#{rule.name}: #{pattern}"
      assert pattern.start_with?('\y(?:') && pattern.end_with?(')\y'), "#{rule.name} lacks word boundaries: #{pattern}"
      assert_equal [ "matches_regex" ], rule.conditions.select { |condition| condition.condition_type == "transaction_name" }.map(&:operator)
    end
  end

  test "every rule only touches uncategorised transactions and only income is limited to inflows" do
    rules = @family.rules.includes(:conditions).index_by(&:name)
    income = rules.delete("SA merchants: Income")

    assert_equal %w[transaction_category transaction_name transaction_type], income.conditions.map(&:condition_type).sort
    assert_equal "income", income.conditions.find { |condition| condition.condition_type == "transaction_type" }.value
    rules.each_value do |rule|
      assert_equal %w[transaction_category transaction_name], rule.conditions.map(&:condition_type).sort, rule.name
    end
    @family.rules.each do |rule|
      assert_equal "is_null", rule.conditions.find { |condition| condition.condition_type == "transaction_category" }.operator
    end
  end

  test "no keyword is listed twice and no keyword matches another rule's pattern except on purpose" do
    keywords = @family.rules.flat_map { |rule| keywords_of(name_pattern(rule)) }

    assert_operator keywords.size, :>, 130
    assert_equal [], keywords.tally.select { |_, count| count > 1 }.keys

    overlaps = pattern_overlaps
    assert_equal ORDER_DEPENDENT_OVERLAPS.sort, overlaps.sort

    positions = @family.rules.pluck(:name, :position).to_h
    ORDER_DEPENDENT_OVERLAPS.each do |owner, keyword, other|
      assert_operator positions.fetch(owner), :<, positions.fetch(other), "#{keyword} must sit above #{other}"
    end
  end

  test "importing the file again restores the rules but keeps a group and the order" do
    group = @family.rule_groups.create!(name: "Mine")
    rule = @family.rules.find_by!(name: "SA merchants: Groceries")
    rule.update!(rule_group: group, active: false, effective_date: Date.new(2025, 1, 1))
    rule.conditions.find_by!(condition_type: "transaction_name").update!(value: '\ymine\y')
    positions = @family.rules.pluck(:name, :position).to_h

    assert_no_difference -> { @family.rules.count } do
      import_rules
    end

    rule.reload
    assert_equal group, rule.rule_group
    assert rule.active
    assert_nil rule.effective_date
    assert_equal shipped_rows.find { |row| row["name"] == rule.name }.then { |row| JSON.parse(row["conditions"]).first["value"] }, name_pattern(rule)
    assert_equal positions, @family.rules.pluck(:name, :position).to_h
    assert_equal @categories_before_import, @family.categories.count
  end

  OUTFLOW_EXAMPLES.each do |category, descriptions|
    test "categorises #{category} statement lines" do
      categories = categorise(descriptions.map { |description| [ description, 120 ] })

      assert_equal descriptions.index_with { category }, categories
    end
  end

  test "categorises income lines when money comes in" do
    categories = categorise(INFLOW_EXAMPLES.map { |description| [ description, -5000 ] })

    assert_equal INFLOW_EXAMPLES.index_with { "Income" }, categories
  end

  test "does not call a salary-like line income when money goes out" do
    categories = categorise(INFLOW_EXAMPLES.map { |description| [ description, 5000 ] })

    assert_equal INFLOW_EXAMPLES.index_with { nil }, categories
  end

  test "money in from an employer named like a merchant is income" do
    categories = categorise(EMPLOYER_LINES.keys.map { |description| [ description, -25_000 ] })

    assert_equal EMPLOYER_LINES.keys.index_with { "Income" }, categories
  end

  test "the same names as money out take the merchant's category" do
    categories = categorise(EMPLOYER_LINES.keys.map { |description| [ description, 900 ] })

    assert_equal EMPLOYER_LINES, categories
  end

  test "leaves substring look-alikes and loose words uncategorised" do
    categories = categorise(MISFIRES.map { |description| [ description, 120 ] })

    assert_equal MISFIRES.index_with { nil }, categories
  end

  # Two rules match a Momentum Health line because the Insurance pattern is loose: the rule higher up in the
  # file claims the category, whatever the later rule says.
  test "the first rule in file order wins when two rules match" do
    entry = create_transaction(account: @account, name: "MOMENTUM HEALTH", amount: 2500)
    rules = @family.rules.index_by(&:name)

    assert rules.fetch("SA merchants: Healthcare").matches_transaction?(entry.transaction)
    assert rules.fetch("SA merchants: Insurance").matches_transaction?(entry.transaction)

    ApplyRulesJob.perform_now(@family)

    assert_equal "Healthcare", entry.transaction.reload.category.name
  end

  test "Uber Eats is not transport and Uber trips are" do
    categories = categorise([ [ "UBER *EATS HELP.UBER.COM", 180 ], [ "UBER TRIP HELP.UBER.COM", 180 ] ])

    assert_equal({ "UBER *EATS HELP.UBER.COM" => "Food & Drink", "UBER TRIP HELP.UBER.COM" => "Transportation" }, categories)
  end

  test "keeps a category the user set" do
    shopping = @family.categories.find_by!(name: "Shopping")
    chosen = create_transaction(account: @account, name: "CHECKERS SIXTY60 SANDTON", amount: 90, category: shopping).transaction
    chosen.lock_attr!(:category_id)
    open = create_transaction(account: @account, name: "CHECKERS SIXTY60 ROSEBANK", amount: 90).transaction

    ApplyRulesJob.perform_now(@family)

    assert_equal shopping, chosen.reload.category
    assert_equal "Groceries", open.reload.category.name
  end

  test "keeps a category that came with an import or sync, however old the transaction" do
    shopping = @family.categories.find_by!(name: "Shopping")
    imported = create_transaction(account: @account, name: "CHECKERS SIXTY60 SANDTON", amount: 90, category: shopping, date: 2.years.ago.to_date).transaction
    imported_unlocked = imported.locked_attributes.key?("category_id")
    old = create_transaction(account: @account, name: "CHECKERS SIXTY60 ROSEBANK", amount: 90, date: 2.years.ago.to_date).transaction

    ApplyRulesJob.perform_now(@family)

    assert_not imported_unlocked
    assert_equal shopping, imported.reload.category
    assert_equal "Groceries", old.reload.category.name
  end

  test "Apply All and Re-apply rule leave set categories alone but still fill empty ones" do
    shopping = @family.categories.find_by!(name: "Shopping")
    set = create_transaction(account: @account, name: "CHECKERS SIXTY60 SANDTON", amount: 90, category: shopping).transaction
    locked = create_transaction(account: @account, name: "CHECKERS SIXTY60 MELROSE", amount: 90, category: shopping).transaction
    locked.lock_attr!(:category_id)
    cleared = create_transaction(account: @account, name: "CHECKERS SIXTY60 ROSEBANK", amount: 90).transaction
    cleared.lock_attr!(:category_id)

    ApplyAllRulesJob.perform_now(@family)

    assert_equal shopping, set.reload.category
    assert_equal shopping, locked.reload.category
    assert_equal "Groceries", cleared.reload.category.name

    cleared.update!(category: nil)
    RuleJob.perform_now(@family.rules.find_by!(name: "SA merchants: Groceries"), ignore_attribute_locks: true)

    assert_equal shopping, set.reload.category
    assert_equal shopping, locked.reload.category
    assert_equal "Groceries", cleared.reload.category.name
  end

  test "running the rules again changes nothing" do
    lines = OUTFLOW_EXAMPLES.values.flatten.first(40) + MISFIRES
    transactions = lines.each_with_index.map { |line, index| create_transaction(account: @account, name: line, amount: 100 + index).transaction }
    ApplyRulesJob.perform_now(@family)
    snapshot = snapshot_of(transactions)
    enrichments = DataEnrichment.count
    second_run_starts = Time.current

    ApplyRulesJob.perform_now(@family)

    second_runs = RuleRun.where(rule: @family.rules).where(executed_at: second_run_starts..)
    assert_equal @family.rules.count, second_runs.count
    assert_equal 0, second_runs.sum(:transactions_modified)
    assert_equal snapshot, snapshot_of(transactions)
    assert_equal enrichments, DataEnrichment.count
  end

  private
    def shipped_rows
      CSV.parse(File.read(CSV_PATH), headers: true)
    end

    def import_rules
      import = @family.imports.create!(type: "RuleImport", raw_file_str: File.read(CSV_PATH), col_sep: ",")
      import.generate_rows_from_csv

      assert import.publishable?
      import.publish
      assert_predicate import.reload, :complete?, import.error
    end

    # Creates the lines as uncategorised transactions, runs the rules as a sync does, and returns
    # each description's category name (nil when it stayed uncategorised).
    def categorise(lines)
      transactions = lines.to_h { |description, amount| [ description, create_transaction(account: @account, name: description, amount: amount).transaction ] }

      ApplyRulesJob.perform_now(@family)

      transactions.transform_values { |transaction| transaction.reload.category&.name }
    end

    def snapshot_of(transactions)
      transactions.map { |transaction| transaction.reload.slice(:id, :category_id, :updated_at, :locked_attributes) }
    end

    def name_pattern(rule)
      rule.conditions.find { |condition| condition.condition_type == "transaction_name" }.value
    end

    # Every keyword of every rule is expanded into sample strings it matches and run against every
    # rule's pattern in Postgres. Returns [owner rule, keyword, other rule] for each sample that
    # another rule also matches, and checks that each sample matches its own rule.
    def pattern_overlaps
      rules = @family.rules.to_a
      samples = rules.flat_map do |rule|
        keywords_of(name_pattern(rule)).flat_map { |keyword| samples_of(keyword).map { |sample| [ rule.name, keyword, sample ] } }
      end
      matching = rules.to_h do |rule|
        matched = ActiveRecord::Base.connection.select_values(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT s FROM unnest(ARRAY[?]::text[]) AS s WHERE s ~* ?", samples.map(&:last).uniq, name_pattern(rule) ])
        )
        [ rule.name, matched.to_set ]
      end

      samples.each { |owner, keyword, sample| assert_includes matching.fetch(owner), sample, "#{keyword} does not match its own rule as #{sample.inspect}" }
      samples.flat_map do |owner, keyword, sample|
        (matching.keys - [ owner ]).select { |other| matching.fetch(other).include?(sample) }.map { |other| [ owner, keyword, other ] }
      end.uniq
    end

    # The alternatives of \y(?:a|b|c)\y, split on the bars outside nested groups.
    def keywords_of(pattern)
      keywords = []
      current = +""
      depth = 0
      escaped = false

      pattern.delete_prefix('\y(?:').delete_suffix(')\y').each_char do |char|
        if escaped
          escaped = false
        elsif char == "\\"
          escaped = true
        elsif char == "("
          depth += 1
        elsif char == ")"
          depth -= 1
        elsif char == "|" && depth.zero?
          keywords << current
          current = +""
          next
        end
        current << char
      end

      keywords << current
    end

    # Strings a keyword matches, one per way through its optional parts and alternatives. Handles the
    # pieces the file uses: \s \w and escaped characters, (?:a|b) groups, and the ? * + quantifiers.
    def samples_of(keyword)
      expand_alternatives(keyword, 0).first
    end

    def expand_alternatives(source, from)
      variants = []
      sequence = [ "" ]
      index = from

      while index < source.length && source[index] != ")"
        if source[index] == "|"
          variants.concat(sequence)
          sequence = [ "" ]
          index += 1
          next
        end

        atom, index = expand_atom(source, index)
        atom = [ "" ] + atom if source[index] == "?"
        index += 1 if %w[? * +].include?(source[index])
        sequence = sequence.product(atom).map(&:join)
      end

      [ variants + sequence, index ]
    end

    def expand_atom(source, index)
      if source[index] == "\\"
        [ [ { "s" => " ", "w" => "x" }.fetch(source[index + 1], source[index + 1]) ], index + 2 ]
      elsif source[index, 3] == "(?:"
        variants, close = expand_alternatives(source, index + 3)
        [ variants, close + 1 ]
      else
        [ [ source[index] ], index + 1 ]
      end
    end
end
