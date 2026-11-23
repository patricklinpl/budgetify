require "test_helper"

# Plan lifecycle (issue #54): PLAN-01 create, PLAN-02 rename, PLAN-03
# settings and display formats, PLAN-04/05 Fresh Start, plus isolation and
# failed-input paths with no partial writes.
class PlanLifecycleApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "lifecycle@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
  end

  teardown { Rails.cache.clear }

  test "PLAN-01 creates exactly one distinct plan with default categories and no accounts" do
    assert_difference -> { @user.budgets.count }, 1 do
      post "/v1/plans", params: { plan: { name: "Household" } }, headers: auth_headers, as: :json
    end

    assert_response :created
    created = response.parsed_body.dig("data", "plan")
    assert_equal "Household", created.fetch("name")
    assert_not_equal @plan.public_id, created.fetch("id")

    get "/v1/plans/#{created.fetch('id')}/categories", headers: auth_headers
    groups = response.parsed_body.dig("data", "category_groups")
    visible = groups.reject { |group| group["hidden"] || group["name"] == Budget::INTERNAL_GROUP_NAME }
    assert_equal PlanLifecycle::DEFAULT_CATEGORY_GROUPS.keys, visible.map { |group| group.fetch("name") }
    assert_equal PlanLifecycle::DEFAULT_CATEGORY_GROUPS.values.flatten.sort,
      visible.flat_map { |group| group.fetch("categories").map { |category| category.fetch("name") } }.sort

    get "/v1/plans/#{created.fetch('id')}/accounts", headers: auth_headers
    assert_empty response.parsed_body.dig("data", "accounts")

    get "/v1/plans/#{created.fetch('id')}/months/#{Date.current.beginning_of_month.iso8601}", headers: auth_headers
    assert_equal 0, response.parsed_body.dig("data", "month", "to_be_budgeted")
    assert_equal 0, @plan.reload.categories.where(name: "Groceries").count, "the other plan is untouched"
  end

  test "PLAN-01 rejects a blank or missing name without creating a plan" do
    assert_no_difference -> { @user.budgets.count } do
      post "/v1/plans", params: { plan: { name: "   " } }, headers: auth_headers, as: :json
      assert_response :bad_request
      post "/v1/plans", params: {}, headers: auth_headers, as: :json
      assert_response :bad_request
      post "/v1/plans", params: { plan: { name: "x" * 101 } }, headers: auth_headers, as: :json
      assert_response :bad_request
    end
  end

  test "PLAN-02 renames the plan and a failed rename keeps the stored name" do
    patch "/v1/plans/#{@plan.public_id}", params: { plan: { name: "  Renamed " } }, headers: auth_headers, as: :json
    assert_response :ok
    assert_equal "Renamed", response.parsed_body.dig("data", "plan", "name")
    assert_equal "Renamed", @plan.reload.name

    patch "/v1/plans/#{@plan.public_id}", params: { plan: { name: "" } }, headers: auth_headers, as: :json
    assert_response :bad_request
    get "/v1/plans/#{@plan.public_id}", headers: auth_headers
    assert_equal "Renamed", response.parsed_body.dig("data", "plan", "name")
  end

  test "PLAN-03 saves currency and date formats and restores them without changing amounts" do
    cash = @plan.accounts.create!(name: "Cash", type: "cash", balance: -300_000)
    debt = @plan.accounts.create!(name: "Card Debt", type: "otherLiability", balance: -9_750_000)

    patch "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers, as: :json, params: { settings: {
      date_format: { format: "YYYY-MM-DD" },
      currency_format: { iso_code: "CAD", currency_symbol: "$", symbol_first: false,
                         decimal_separator: ",", group_separator: ".", decimal_digits: 2 }
    } }
    assert_response :ok

    get "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers
    settings = response.parsed_body.dig("data", "settings")
    assert_equal "YYYY-MM-DD", settings.dig("date_format", "format")
    assert_equal "123.456,78", settings.dig("currency_format", "example_format")
    assert_equal "CAD", settings.dig("currency_format", "iso_code")

    format = @plan.reload.currency_format
    assert_equal "-300,00$", format.format_milliunits(-300_000)
    assert_equal "-9.750,00$", format.format_milliunits(-9_750_000)
    assert_equal(-300_000, cash.reload.balance)
    assert_equal(-9_750_000, debt.reload.balance)

    patch "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers, as: :json, params: { settings: {
      date_format: { format: "DD/MM/YYYY" },
      currency_format: { iso_code: "USD", currency_symbol: "$", symbol_first: true,
                         decimal_separator: ".", group_separator: ",", decimal_digits: 2 }
    } }
    assert_response :ok
    restored = @plan.reload.currency_format
    assert_equal "-$300.00", restored.format_milliunits(-300_000)
    assert_equal "-$9,750.00", restored.format_milliunits(-9_750_000)
    assert_equal "DD/MM/YYYY", @plan.date_format
    assert_equal(-300_000, cash.reload.balance)
  end

  test "currency formatting rounds half away from zero at display precision and never changes the stored amount" do
    format = CurrencyFormat.default
    assert_equal "$0.01", format.format_milliunits(5)
    assert_equal "-$0.01", format.format_milliunits(-5)
    assert_equal "$0.00", format.format_milliunits(4)
    assert_equal "$1,234,567.89", format.format_milliunits(1_234_567_890)
    zero_digits, errors = CurrencyFormat.build({ "decimal_digits" => 0 })
    assert_empty errors
    assert_equal "$1,235", zero_digits.format_milliunits(1_234_500)
  end

  test "PLAN-03 invalid settings are rejected and nothing is saved" do
    bad = [
      { date_format: { format: "YY-M-D" } },
      { currency_format: { iso_code: "usd" } },
      { currency_format: { decimal_digits: 9 } },
      { currency_format: { decimal_digits: "2" } },
      { currency_format: { decimal_separator: ",", group_separator: "," } },
      { currency_format: { currency_symbol: "" } },
      { currency_format: { symbol_first: "yes" } }
    ]
    bad.each do |settings|
      patch "/v1/plans/#{@plan.public_id}/settings", params: { settings: settings }, headers: auth_headers, as: :json
      assert_response :bad_request, settings.inspect
    end
    patch "/v1/plans/#{@plan.public_id}/settings", params: {}, headers: auth_headers, as: :json
    assert_response :bad_request
    assert_equal "MM/DD/YYYY", @plan.reload.date_format
    assert_equal CurrencyFormat.default.as_json, @plan.currency_format.as_json
  end

  test "PLAN-04 and PLAN-05 Fresh Start keeps structure and targets, zeroes accounts, and archives the original" do
    group = @plan.category_groups.create!(name: "Savings Goals")
    target = group.categories.create!(budget: @plan, name: "Holiday", goal_type: "TB", goal_target: 200_000,
      goal_creation_month: Date.current.beginning_of_month)
    accounts = %w[Checking Savings Cash].zip(%w[checking savings cash]).map do |name, type|
      Account.open!(budget: @plan, attributes: { "name" => name, "type" => type, "balance" => 500_000 })
    end
    card = Account.open!(budget: @plan, attributes: { "name" => "Visa", "type" => "creditCard", "balance" => 0 })
    payee = @plan.payees.create!(name: "Landlord")
    @plan.scheduled_transactions.create!(account: accounts.first, payee: payee, category: target,
      date_first: Date.current, date_next: Date.current, frequency: "monthly", amount: -100_000)
    original_transactions = @plan.transactions.count
    assert_operator original_transactions, :>, 0
    original_id = @plan.public_id

    assert_difference -> { @user.budgets.count }, 1 do
      post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    end
    assert_response :created
    fresh = response.parsed_body.dig("data", "plan")
    archived = response.parsed_body.dig("data", "archived_plan")

    assert_not_equal original_id, fresh.fetch("id")
    assert_equal "Everyday", fresh.fetch("name")
    assert_equal original_id, archived.fetch("id")
    assert_equal PlanLifecycle.archived_name("Everyday"), archived.fetch("name")

    new_plan = @user.budgets.find_by!(public_id: fresh.fetch("id"))
    # No history carries; each account has only its zero Starting Balance row dated today.
    assert_equal [ [ "Starting Balance", 0, Date.current ] ] * 4,
      new_plan.transactions.includes(:payee).map { |t| [ t.payee.name, t.amount, t.date ] }
    assert_equal accounts.map(&:name) + [ "Visa" ], new_plan.accounts.order(:id).pluck(:name)
    assert_equal [ 0 ], new_plan.accounts.pluck(:balance).uniq
    assert_empty new_plan.accounts.pluck(:id) & @plan.accounts.pluck(:id)
    assert_equal [ 0 ], new_plan.accounts.pluck(:cleared_balance).uniq

    holiday = new_plan.categories.not_deleted.find_by!(name: "Holiday")
    assert_equal [ "TB", 200_000, nil ], [ holiday.goal_type, holiday.goal_target, holiday.goal_target_date ]
    assert_not_equal target.id, holiday.id
    assert_equal "Savings Goals", holiday.category_group.name
    assert_equal 1, new_plan.categories.not_deleted.where(payment_account_id: new_plan.accounts.find_by!(name: "Visa").id).count

    scheduled = new_plan.scheduled_transactions.not_deleted.sole
    assert_equal [ "monthly", -100_000, holiday.id ], [ scheduled.frequency, scheduled.amount, scheduled.category_id ]
    assert_equal new_plan.accounts.find_by!(name: "Checking").id, scheduled.account_id

    @plan.reload
    assert_equal original_transactions, @plan.transactions.count
    assert_equal 500_000, @plan.accounts.find_by!(name: "Checking").balance
    assert_equal PlanLifecycle.archived_name("Everyday"), @plan.name
    assert_equal card.id, @plan.accounts.find_by!(name: "Visa").id
  end

  test "Fresh Start with an invalid name changes nothing" do
    assert_no_difference -> { @user.budgets.count } do
      post "/v1/plans/#{@plan.public_id}/fresh_start", params: { plan: { name: "" } }, headers: auth_headers, as: :json
    end
    assert_response :bad_request
    assert_equal "Everyday", @plan.reload.name
  end

  test "another user's plan is not found for rename, settings and Fresh Start" do
    other = User.create!(email_address: "other@example.com", password: "password123").budgets.create!(name: "Theirs")

    patch "/v1/plans/#{other.public_id}", params: { plan: { name: "Mine" } }, headers: auth_headers, as: :json
    assert_response :not_found
    patch "/v1/plans/#{other.public_id}/settings", params: { settings: { date_format: { format: "YYYY-MM-DD" } } }, headers: auth_headers, as: :json
    assert_response :not_found
    assert_no_difference -> { Budget.count } do
      post "/v1/plans/#{other.public_id}/fresh_start", headers: auth_headers, as: :json
    end
    assert_response :not_found
    assert_equal "Theirs", other.reload.name
  end

  test "malformed plan payloads are 400 and never 500, including Fresh Start shapes" do
    bad_plans = [ "text", [ "x" ], [ { name: "x" } ], 7, { name: [ "x" ] }, { name: { a: 1 } }, { name: 5 }, { name: "bad\u0000name" }, { name: "tab\tname" } ]
    assert_no_difference -> { Budget.count } do
      bad_plans.each do |plan|
        post "/v1/plans", params: { plan: plan }, headers: auth_headers, as: :json
        assert_response :bad_request, "create #{plan.inspect}"
        post "/v1/plans/#{@plan.public_id}/fresh_start", params: { plan: plan }, headers: auth_headers, as: :json
        assert_response :bad_request, "fresh_start #{plan.inspect}"
        patch "/v1/plans/#{@plan.public_id}", params: { plan: plan }, headers: auth_headers, as: :json
        assert_response :bad_request, "rename #{plan.inspect}"
      end
    end
    assert_equal "Everyday", @plan.reload.name
  end

  test "malformed settings payloads are 400 and save nothing" do
    [ "text", [ 1 ], { date_format: "YYYY-MM-DD" }, { date_format: [ "x" ] }, { date_format: { format: [ "YYYY-MM-DD" ] } },
      { currency_format: "USD" }, { currency_format: [ 1 ] }, { currency_format: { iso_code: { a: 1 } } },
      { currency_format: { currency_symbol: [ "$" ] } }, { currency_format: { decimal_digits: "2" } } ].each do |settings|
      patch "/v1/plans/#{@plan.public_id}/settings", params: { settings: settings }, headers: auth_headers, as: :json
      assert_response :bad_request, settings.inspect
    end
    assert_equal "MM/DD/YYYY", @plan.reload.date_format
    assert_equal CurrencyFormat.default.as_json, @plan.currency_format.as_json
  end

  test "archived names stay within the limit, do not nest, and can be saved again" do
    @plan.update!(name: "n" * 100)
    post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    archived = @plan.reload.name
    assert_operator archived.length, :<=, 100
    patch "/v1/plans/#{@plan.public_id}", params: { plan: { name: archived } }, headers: auth_headers, as: :json
    assert_response :ok

    fresh_id = response.parsed_body.dig("data", "plan", "id") && Budget.find_by!(name: "n" * 100).public_id
    post "/v1/plans/#{fresh_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    assert_equal 1, Budget.find_by!(public_id: fresh_id).name.scan("(archived").size

    post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    assert_equal 1, response.parsed_body.dig("data", "archived_plan", "name").scan("(archived").size
    # The archived name was shortened to fit, so a Fresh Start from it starts from the shortened base.
    assert_equal archived.sub(PlanLifecycle::ARCHIVED_SUFFIX, ""), response.parsed_body.dig("data", "plan", "name")
  end

  test "Fresh Start carries closed accounts as closed and schedules that use them unchanged" do
    open_account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    closed = Account.open!(budget: @plan, attributes: { "name" => "Old", "type" => "checking", "balance" => 0 })
    closed.update!(closed: true)
    @plan.scheduled_transactions.create!(account: closed, date_first: Date.current, date_next: Date.current,
      frequency: "monthly", amount: -5_000)
    @plan.scheduled_transactions.create!(account: open_account, transfer_account: closed, date_first: Date.current + 30,
      date_next: Date.current + 30, frequency: "never", amount: -1_000)

    post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    assert_equal({ "open_accounts_carried" => 1, "closed_accounts_carried_closed" => 1, "scheduled_transactions_carried" => 2 },
      response.parsed_body.dig("data", "carry_report"))
    fresh = Budget.find_by!(public_id: response.parsed_body.dig("data", "plan", "id"))
    assert_equal [ [ "Checking", false ], [ "Old", true ] ], fresh.accounts.order(:id).pluck(:name, :closed)
    assert_equal [ -5_000, -1_000 ], fresh.scheduled_transactions.order(:id).pluck(:amount)
    assert_equal "Old", fresh.scheduled_transactions.order(:id).last.transfer_account.name
  end

  test "Fresh Start is blocked, with nothing changed, when a schedule uses a deleted account" do
    gone = Account.open!(budget: @plan, attributes: { "name" => "Gone", "type" => "checking", "balance" => 0 })
    scheduled = @plan.scheduled_transactions.create!(account: gone, date_first: Date.current, date_next: Date.current,
      frequency: "monthly", amount: -5_000)
    gone.update!(deleted: true)

    assert_no_difference -> { Budget.count } do
      post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal [ scheduled.public_id ], response.parsed_body.fetch("blocking_scheduled_transactions").map { |b| b["id"] }
    assert_equal "Everyday", @plan.reload.name
  end

  test "Fresh Start carries a schedule that pays a credit card to the new card's payment category" do
    checking = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    visa = Account.open!(budget: @plan, attributes: { "name" => "Visa", "type" => "creditCard", "balance" => 0 })
    old_payment = @plan.categories.find_by!(payment_account_id: visa.id)
    payee = @plan.payees.create!(name: "Payment: Visa", transfer_account_id: visa.id)
    @plan.scheduled_transactions.create!(account: checking, payee: payee, category: old_payment, transfer_account: visa,
      date_first: Date.current, date_next: Date.current, frequency: "monthly", amount: -15_000, memo: "ccpay")
    @plan.scheduled_transactions.create!(account: visa, transfer_account: checking, date_first: Date.current,
      date_next: Date.current, frequency: "monthly", amount: 15_000, memo: "ccpay")

    post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    fresh = Budget.find_by!(public_id: response.parsed_body.dig("data", "plan", "id"))
    new_visa = fresh.accounts.find_by!(name: "Visa")
    new_payment = fresh.categories.find_by!(payment_account_id: new_visa.id)
    assert_not_equal old_payment.id, new_payment.id
    carried = fresh.scheduled_transactions.order(:id).to_a
    assert_equal [ -15_000, 15_000 ], carried.map(&:amount)
    assert_equal new_payment.id, carried.first.category_id
    assert_equal new_visa.id, carried.first.transfer_account_id
    assert_equal "ccpay", carried.last.memo
  end

  test "Fresh Start keeps payee, flag and memo metadata on carried scheduled transactions" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    payee = @plan.payees.create!(name: "Landlord")
    @plan.scheduled_transactions.create!(account: account, payee: payee, date_first: Date.current, date_next: Date.current,
      frequency: "monthly", amount: -1_000, memo: "rent", flag_color: "red", flag_name: "Rent")

    post "/v1/plans/#{@plan.public_id}/fresh_start", headers: auth_headers, as: :json
    assert_response :created
    carried = Budget.find_by!(public_id: response.parsed_body.dig("data", "plan", "id")).scheduled_transactions.sole
    assert_equal [ "Landlord", "rent", "red", "Rent" ], [ carried.payee.name, carried.memo, carried.flag_color, carried.flag_name ]
    assert_not_equal payee.id, carried.payee_id
  end

  test "the eight number formats render a six-digit integer with two decimals through settings and the API" do
    formats = {
      "123,456.78" => { group_separator: ",", decimal_separator: "." },
      "123.456,78" => { group_separator: ".", decimal_separator: "," },
      "123 456.78" => { group_separator: " ", decimal_separator: "." },
      "123'456.78" => { group_separator: "'", decimal_separator: "." },
      "123 456-78" => { group_separator: " ", decimal_separator: "-" },
      "123 456,78" => { group_separator: " ", decimal_separator: "," },
      "123,456/78" => { group_separator: ",", decimal_separator: "/" },
      "1,23,456.78" => { group_separator: ",", decimal_separator: ".", group_style: "indian" }
    }
    account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 123_456_780 })
    formats.each do |expected, values|
      patch "/v1/plans/#{@plan.public_id}/settings", params: { settings: { currency_format: values.merge(currency_symbol: "$", symbol_first: true, display_symbol: false) } },
        headers: auth_headers, as: :json
      assert_response :ok, expected
      assert_equal expected, @plan.reload.currency_format.format_number(123_456_780)
      get "/v1/plans/#{@plan.public_id}/accounts/#{account.public_id}", headers: auth_headers
      assert_equal expected, response.parsed_body.dig("data", "account", "balance_formatted"), expected
      assert_equal 123456.78, response.parsed_body.dig("data", "account", "balance_currency")
      get "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers
      assert_equal values.fetch(:group_style, "western"), response.parsed_body.dig("data", "settings", "currency_format", "group_style")
    end
    assert_equal "-1,23,456.78", CurrencyFormat.new(group_style: "indian", display_symbol: false).format_milliunits(-123_456_780)
    assert_equal "12,34,56,789.00", CurrencyFormat.new(group_style: "indian", display_symbol: false).format_milliunits(123_456_789_000)
    assert_equal "999", CurrencyFormat.new(group_style: "indian", display_symbol: false, decimal_digits: 0).format_milliunits(999_000)

    patch "/v1/plans/#{@plan.public_id}/settings", params: { settings: { currency_format: { group_style: "lakh" } } }, headers: auth_headers, as: :json
    assert_response :bad_request
  end

  test "unauthenticated writes are rejected" do
    post "/v1/plans", params: { plan: { name: "Nope" } }, as: :json
    assert_response :unauthorized
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
