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
    assert_equal 0, new_plan.transactions.count
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

  test "unauthenticated writes are rejected" do
    post "/v1/plans", params: { plan: { name: "Nope" } }, as: :json
    assert_response :unauthorized
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
