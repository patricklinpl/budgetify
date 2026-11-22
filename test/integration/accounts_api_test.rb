require "test_helper"

# Request-level checks for the accounts endpoints (issue #28):
# GET/POST /v1/plans/:plan_id/accounts, GET /v1/plans/:plan_id/accounts/:account_id.
class AccountsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "accounts@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/accounts"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "GET accounts lists the plan's accounts with server_knowledge" do
    @plan.accounts.create!(name: "Checking", type: "checking", balance: 123450)

    get "/v1/plans/#{@plan.public_id}/accounts", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    accounts = data.fetch("accounts")
    assert_equal 1, accounts.size
    account = accounts.first
    assert_equal "Checking", account.fetch("name")
    assert_equal "checking", account.fetch("type")
    assert_equal true, account.fetch("on_budget")
    assert_equal false, account.fetch("closed")
    assert_equal false, account.fetch("deleted")
    assert_equal 123450, account.fetch("balance")
    assert_equal 123.45, account.fetch("balance_currency")
    assert_equal "$123.45", account.fetch("balance_formatted")
    assert account.fetch("transfer_payee_id").present?
  end

  test "POST accounts creates an account with its transfer payee" do
    assert_difference -> { @plan.accounts.count } => 1, -> { @plan.payees.count } => 2, -> { @plan.transactions.count } => 1 do
      post "/v1/plans/#{@plan.public_id}/accounts",
        params: { account: { name: "Savings", type: "savings", balance: 500000 } }, headers: auth_headers, as: :json
    end

    assert_response :created
    account = response.parsed_body.dig("data", "account")
    assert_equal "Savings", account.fetch("name")
    assert_equal 500000, account.fetch("balance")
    payee = @plan.payees.find_by(public_id: account.fetch("transfer_payee_id"))
    assert_not_nil payee
    assert_equal "Transfer : Savings", payee.name
  end

  test "POST accounts rejects types outside SaveAccountType" do
    post "/v1/plans/#{@plan.public_id}/accounts",
      params: { account: { name: "Mortgage", type: "mortgage", balance: 0 } }, headers: auth_headers, as: :json

    assert_response :bad_request
    error = response.parsed_body.fetch("error")
    assert_equal "400", error.fetch("id")
    assert_equal "bad_request", error.fetch("name")
  end

  test "GET one account by uuid" do
    account = @plan.accounts.create!(name: "Cash", type: "cash", balance: 0)

    get "/v1/plans/#{@plan.public_id}/accounts/#{account.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal account.public_id, response.parsed_body.dig("data", "account", "id")
  end

  test "GET one account response has no server_knowledge (spec: AccountResponse)" do
    account = @plan.accounts.create!(name: "Cash", type: "cash", balance: 0)

    get "/v1/plans/#{@plan.public_id}/accounts/#{account.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal %w[account], response.parsed_body.fetch("data").keys
  end

  test "POST without an account wrapper returns 400 in the error envelope" do
    post "/v1/plans/#{@plan.public_id}/accounts",
      params: { wrong: { name: "Nope" } }, headers: auth_headers, as: :json

    assert_response :bad_request
    error = response.parsed_body.fetch("error")
    assert_equal "400", error.fetch("id")
    assert_equal "bad_request", error.fetch("name")
  end

  test "GET unknown account returns 404.2 resource_not_found" do
    get "/v1/plans/#{@plan.public_id}/accounts/00000000-0000-0000-0000-000000000000", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")
  end

  test "delta requests return only accounts changed after the given knowledge, with tombstones" do
    account = @plan.accounts.create!(name: "Checking", type: "checking", balance: 0)
    knowledge = account.knowledge
    other = @plan.accounts.create!(name: "Savings", type: "savings", balance: 0)
    account.update!(deleted: true)

    get "/v1/plans/#{@plan.public_id}/accounts", params: { last_knowledge_of_server: knowledge }, headers: auth_headers

    assert_response :ok
    accounts = response.parsed_body.dig("data", "accounts")
    assert_equal [ account.public_id, other.public_id ].sort, accounts.map { |a| a.fetch("id") }.sort
    tombstone = accounts.detect { |a| a.fetch("id") == account.public_id }
    assert_equal true, tombstone.fetch("deleted")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
