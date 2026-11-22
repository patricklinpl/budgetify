require "test_helper"

# Request-level checks for the money movement endpoints (issue #32):
# GET /v1/plans/:plan_id/money_movements,
# GET /v1/plans/:plan_id/months/:month/money_movements,
# GET /v1/plans/:plan_id/money_movement_groups,
# GET /v1/plans/:plan_id/months/:month/money_movement_groups.
class MoneyMovementsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "movements@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
    @groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    @current = Date.current.beginning_of_month
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/money_movements"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "unknown plans get a 404.2 in the error envelope" do
    get "/v1/plans/does-not-exist/money_movements", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")
  end

  test "GET money_movements lists movements with server_knowledge" do
    get "/v1/plans/#{@plan.public_id}/money_movements", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    assert_equal [], data.fetch("money_movements")
  end

  test "assigning a month amount records a movement from Ready to Assign" do
    assign(@groceries, @current, 500000)

    get "/v1/plans/#{@plan.public_id}/money_movements", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    movements = data.fetch("money_movements")
    assert_equal 1, movements.size
    movement = movements.first
    assert_equal @current.iso8601, movement.fetch("month")
    assert_equal 500000, movement.fetch("amount")
    assert_equal 500.0, movement.fetch("amount_currency")
    assert_equal "$500.00", movement.fetch("amount_formatted")
    assert_nil movement.fetch("from_category_id") # null means from Ready to Assign
    assert_equal @groceries.public_id, movement.fetch("to_category_id")
    assert_equal @user.public_id, movement.fetch("performed_by_user_id")
    assert_not_nil movement.fetch("moved_at")
    assert_not_nil movement.fetch("money_movement_group_id")
    assert_nil movement.fetch("note")
  end

  test "unassigning records a movement back to Ready to Assign" do
    assign(@groceries, @current, 500000)
    assign(@groceries, @current, 200000)

    get "/v1/plans/#{@plan.public_id}/money_movements", headers: auth_headers

    movements = response.parsed_body.fetch("data").fetch("money_movements")
    assert_equal 2, movements.size
    back = movements.last
    assert_equal 300000, back.fetch("amount")
    assert_equal @groceries.public_id, back.fetch("from_category_id")
    assert_nil back.fetch("to_category_id") # null means to Ready to Assign
  end

  test "GET months/:month/money_movements scopes to the month" do
    assign(@groceries, @current, 500000)
    previous = @current.prev_month
    assign(@groceries, previous, 100000)

    get "/v1/plans/#{@plan.public_id}/months/#{previous.iso8601}/money_movements", headers: auth_headers

    assert_response :ok
    movements = response.parsed_body.fetch("data").fetch("money_movements")
    assert_equal 1, movements.size
    assert_equal 100000, movements.first.fetch("amount")
  end

  test "GET months/:month/money_movements rejects future months with a 400" do
    future = @current.next_month
    get "/v1/plans/#{@plan.public_id}/months/#{future.iso8601}/money_movements", headers: auth_headers

    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.fetch("error").fetch("name")
  end

  test "GET months/:month/money_movements rejects invalid month formats with a 400" do
    get "/v1/plans/#{@plan.public_id}/months/not-a-month/money_movements", headers: auth_headers

    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.fetch("error").fetch("name")
  end

  test "GET money_movement_groups lists groups with server_knowledge" do
    assign(@groceries, @current, 500000)

    get "/v1/plans/#{@plan.public_id}/money_movement_groups", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    groups = data.fetch("money_movement_groups")
    assert_equal 1, groups.size
    group = groups.first
    assert_equal @current.iso8601, group.fetch("month")
    assert_equal @user.public_id, group.fetch("performed_by_user_id")
    assert_not_nil group.fetch("group_created_at")
    assert_nil group.fetch("note")
  end

  test "GET months/:month/money_movement_groups scopes to the month" do
    assign(@groceries, @current, 500000)
    previous = @current.prev_month
    assign(@groceries, previous, 100000)

    get "/v1/plans/#{@plan.public_id}/months/#{@current.iso8601}/money_movement_groups", headers: auth_headers

    assert_response :ok
    groups = response.parsed_body.fetch("data").fetch("money_movement_groups")
    assert_equal 1, groups.size
    assert_equal @current.iso8601, groups.first.fetch("month")
  end

  test "GET money_movements with last_knowledge_of_server returns only changed movements" do
    get "/v1/plans/#{@plan.public_id}/money_movements", headers: auth_headers
    knowledge = response.parsed_body.fetch("data").fetch("server_knowledge")

    assign(@groceries, @current, 500000)

    get "/v1/plans/#{@plan.public_id}/money_movements", headers: auth_headers, params: { last_knowledge_of_server: knowledge }

    assert_response :ok
    movements = response.parsed_body.fetch("data").fetch("money_movements")
    assert_equal 1, movements.size
    assert_equal 500000, movements.first.fetch("amount")
  end

  private
    def assign(category, month, budgeted)
      patch "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}",
        params: { category: { budgeted: budgeted } },
        headers: auth_headers, as: :json
      assert_response :ok
    end

    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
