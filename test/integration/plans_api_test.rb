require "test_helper"

# Request-level checks for the plans endpoints (issue #27):
# GET /v1/plans, GET /v1/plans/:plan_id, GET /v1/plans/:plan_id/settings.
class PlansApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "plans@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "GET /v1/plans lists the user's plans in the envelope" do
    get "/v1/plans", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_nil data.fetch("default_plan")
    assert data.key?("server_knowledge")

    plans = data.fetch("plans")
    assert_equal 1, plans.size
    summary = plans.first
    assert_equal @plan.public_id, summary.fetch("id")
    assert_equal "Everyday", summary.fetch("name")
    assert summary.fetch("last_modified_on").present?
    assert_equal({ "format" => "MM/DD/YYYY" }, summary.fetch("date_format"))
    assert_equal "USD", summary.dig("currency_format", "iso_code")
    assert_equal 2, summary.dig("currency_format", "decimal_digits")
    assert_not summary.key?("accounts")
  end

  test "GET /v1/plans embeds accounts only when include_accounts=true" do
    get "/v1/plans", params: { include_accounts: true }, headers: auth_headers

    assert_response :ok
    assert_equal [], response.parsed_body.dig("data", "plans", 0, "accounts")
  end

  test "GET /v1/plans delta returns only plans changed after the given knowledge, with tombstones" do
    knowledge = @user.reload.server_knowledge
    other = @user.budgets.create!(name: "Other")
    @plan.update!(deleted: true)

    get "/v1/plans", params: { last_knowledge_of_server: knowledge }, headers: auth_headers

    assert_response :ok
    plans = response.parsed_body.dig("data", "plans")
    assert_equal [ @plan.public_id, other.public_id ].sort, plans.map { |p| p.fetch("id") }.sort
    tombstone = plans.detect { |p| p.fetch("id") == @plan.public_id }
    assert_equal true, tombstone.fetch("deleted")
  end

  test "GET /v1/plans/:plan_id returns one plan by UUID" do
    get "/v1/plans/#{@plan.public_id}", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal @plan.public_id, data.dig("plan", "id")
    assert data.key?("server_knowledge")
    assert_not data.fetch("plan").key?("accounts")
  end

  test "GET /v1/plans/last-used resolves the most recently used plan" do
    @user.budgets.create!(name: "Newer")
    get "/v1/plans/last-used", headers: auth_headers
    assert_response :ok
    assert_equal @user.budgets.find_by(name: "Newer").public_id, response.parsed_body.dig("data", "plan", "id")
  end

  test "GET /v1/plans/:plan_id embeds accounts when include_accounts=true" do
    get "/v1/plans/#{@plan.public_id}", params: { include_accounts: true }, headers: auth_headers

    assert_response :ok
    assert_equal [], response.parsed_body.dig("data", "plan", "accounts")
  end

  test "GET /v1/plans/:plan_id returns 404.2 resource_not_found for unknown or deleted plans" do
    get "/v1/plans/#{SecureRandom.uuid}", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")

    @plan.update!(deleted: true)
    get "/v1/plans/#{@plan.public_id}", headers: auth_headers
    assert_response :not_found
  end

  test "GET /v1/plans/:plan_id/settings returns the plan's date and currency formats" do
    get "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers

    assert_response :ok
    settings = response.parsed_body.dig("data", "settings")
    assert_equal({ "format" => "MM/DD/YYYY" }, settings.fetch("date_format"))
    currency = settings.fetch("currency_format")
    assert_equal "USD", currency.fetch("iso_code")
    assert_equal "$", currency.fetch("currency_symbol")
    assert_equal true, currency.fetch("symbol_first")
  end

  test "persisted plan settings are reflected in the responses" do
    @plan.update!(
      date_format: "DD.MM.YYYY",
      currency_format: CurrencyFormat.new(iso_code: "EUR", currency_symbol: "€", symbol_first: false).as_json
    )

    get "/v1/plans/#{@plan.public_id}/settings", headers: auth_headers

    assert_response :ok
    settings = response.parsed_body.dig("data", "settings")
    assert_equal({ "format" => "DD.MM.YYYY" }, settings.fetch("date_format"))
    assert_equal "EUR", settings.dig("currency_format", "iso_code")
    assert_equal "€", settings.dig("currency_format", "currency_symbol")
    assert_equal false, settings.dig("currency_format", "symbol_first")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
