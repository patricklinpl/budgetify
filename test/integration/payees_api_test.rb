require "test_helper"

# Request-level checks for the payee endpoints (issue #30):
# GET/POST /v1/plans/:plan_id/payees, GET/PATCH .../payees/:payee_id,
# GET .../payee_locations, GET .../payee_locations/:id,
# GET .../payees/:payee_id/payee_locations.
class PayeesApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "payees@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/payees"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "GET payees lists payees with server_knowledge" do
    @plan.payees.create!(name: "Grocery Store")

    get "/v1/plans/#{@plan.public_id}/payees", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    names = data.fetch("payees").map { |p| p.fetch("name") }
    assert_includes names, "Grocery Store"
    payee = data.fetch("payees").find { |p| p.fetch("name") == "Grocery Store" }
    assert_nil payee.fetch("transfer_account_id")
    assert_equal false, payee.fetch("deleted")
  end

  test "accounts auto-create transfer payees pointing at the account" do
    post "/v1/plans/#{@plan.public_id}/accounts",
      params: { account: { name: "Chequing", type: "checking", balance: 100_000 } },
      headers: auth_headers, as: :json

    assert_response :created
    account_id = response.parsed_body.fetch("data").fetch("account").fetch("id")

    get "/v1/plans/#{@plan.public_id}/payees", headers: auth_headers

    transfer = response.parsed_body.fetch("data").fetch("payees").find { |p| p.fetch("transfer_account_id") == account_id }
    assert transfer.present?
    assert_equal "Transfer : Chequing", transfer.fetch("name")
  end

  test "renaming an account renames its transfer payee" do
    account = @plan.accounts.create!(name: "Old Name", type: "checking", balance: 0)
    account.update!(name: "New Name")

    get "/v1/plans/#{@plan.public_id}/payees", headers: auth_headers

    transfer = response.parsed_body.fetch("data").fetch("payees").find { |p| p.fetch("transfer_account_id") == account.public_id }
    assert_equal "Transfer : New Name", transfer.fetch("name")
  end

  test "POST payees creates a payee and returns server_knowledge" do
    post "/v1/plans/#{@plan.public_id}/payees",
      params: { payee: { name: "Coffee Shop" } },
      headers: auth_headers, as: :json

    assert_response :created
    data = response.parsed_body.fetch("data")
    assert_equal @plan.reload.server_knowledge, data.fetch("server_knowledge")
    assert_equal "Coffee Shop", data.fetch("payee").fetch("name")
  end

  test "POST payees rejects duplicate names" do
    @plan.payees.create!(name: "Grocery Store")

    post "/v1/plans/#{@plan.public_id}/payees",
      params: { payee: { name: "grocery store" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.fetch("error").fetch("name")
  end

  test "POST payees rejects names with characters other than letters numbers and spaces" do
    post "/v1/plans/#{@plan.public_id}/payees",
      params: { payee: { name: "Store #1" } },
      headers: auth_headers, as: :json

    assert_response :bad_request

    post "/v1/plans/#{@plan.public_id}/payees",
      params: { payee: { name: "" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "GET payee returns the payee and 404.2 for unknown ids" do
    payee = @plan.payees.create!(name: "Coffee Shop")

    get "/v1/plans/#{@plan.public_id}/payees/#{payee.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal payee.public_id, response.parsed_body.fetch("data").fetch("payee").fetch("id")

    get "/v1/plans/#{@plan.public_id}/payees/00000000-0000-0000-0000-000000000000", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")
  end

  test "PATCH payee renames and returns server_knowledge" do
    payee = @plan.payees.create!(name: "Coffee Shop")

    patch "/v1/plans/#{@plan.public_id}/payees/#{payee.public_id}",
      params: { payee: { name: "Tea Shop" } },
      headers: auth_headers, as: :json

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "Tea Shop", data.fetch("payee").fetch("name")
    assert_equal @plan.reload.server_knowledge, data.fetch("server_knowledge")
  end

  test "PATCH payee rejects duplicate names" do
    @plan.payees.create!(name: "Grocery Store")
    payee = @plan.payees.create!(name: "Coffee Shop")

    patch "/v1/plans/#{@plan.public_id}/payees/#{payee.public_id}",
      params: { payee: { name: "Grocery Store" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "PATCH transfer payee returns 400" do
    account = @plan.accounts.create!(name: "Chequing", type: "checking", balance: 0)
    transfer = account.transfer_payee

    patch "/v1/plans/#{@plan.public_id}/payees/#{transfer.public_id}",
      params: { payee: { name: "Renamed" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "GET payees supports last_knowledge_of_server delta requests with tombstones" do
    @plan.payees.create!(name: "First")
    knowledge = @plan.reload.server_knowledge
    second = @plan.payees.create!(name: "Second")
    second.update!(deleted: true)
    @plan.payees.create!(name: "Third")

    get "/v1/plans/#{@plan.public_id}/payees?last_knowledge_of_server=#{knowledge}", headers: auth_headers

    assert_response :ok
    payees = response.parsed_body.fetch("data").fetch("payees")
    names = payees.map { |p| p.fetch("name") }
    assert_not_includes names, "First"
    assert_includes names, "Second"
    assert_includes names, "Third"
    tombstone = payees.find { |p| p.fetch("name") == "Second" }
    assert_equal true, tombstone.fetch("deleted")
  end

  test "GET payee_locations returns an empty list until locations exist" do
    get "/v1/plans/#{@plan.public_id}/payee_locations", headers: auth_headers

    assert_response :ok
    assert_equal [], response.parsed_body.fetch("data").fetch("payee_locations")
  end

  test "GET payee_locations lists locations and serves them individually and per payee" do
    payee = @plan.payees.create!(name: "Coffee Shop")
    location = payee.payee_locations.create!(latitude: "49.2827", longitude: "-123.1207")

    get "/v1/plans/#{@plan.public_id}/payee_locations", headers: auth_headers

    assert_response :ok
    listed = response.parsed_body.fetch("data").fetch("payee_locations")
    assert_equal 1, listed.size
    assert_equal location.public_id, listed.first.fetch("id")
    assert_equal payee.public_id, listed.first.fetch("payee_id")
    assert_equal "49.2827", listed.first.fetch("latitude")
    assert_equal "-123.1207", listed.first.fetch("longitude")
    assert_equal false, listed.first.fetch("deleted")

    get "/v1/plans/#{@plan.public_id}/payee_locations/#{location.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal location.public_id, response.parsed_body.fetch("data").fetch("payee_location").fetch("id")

    get "/v1/plans/#{@plan.public_id}/payees/#{payee.public_id}/payee_locations", headers: auth_headers

    assert_response :ok
    assert_equal [ location.public_id ], response.parsed_body.fetch("data").fetch("payee_locations").map { |l| l.fetch("id") }
  end

  test "GET payee_location returns 404.2 for unknown ids" do
    get "/v1/plans/#{@plan.public_id}/payee_locations/00000000-0000-0000-0000-000000000000", headers: auth_headers

    assert_response :not_found
    assert_equal "404.2", response.parsed_body.fetch("error").fetch("id")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
