require "test_helper"

# Request-level checks for the months endpoints (issue #31):
# GET /v1/plans/:plan_id/months, GET /v1/plans/:plan_id/months/:month.
class MonthsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "months@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/months"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "unknown plans get a 404.2 in the error envelope" do
    get "/v1/plans/does-not-exist/months", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")
  end

  test "GET months lists plan months with rollups and server_knowledge" do
    get "/v1/plans/#{@plan.public_id}/months", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    months = data.fetch("months")
    current = Date.current.beginning_of_month
    listed = months.map { |m| m.fetch("month") }
    assert_equal listed.uniq, listed
    assert_includes listed, current.iso8601
    summary = months.find { |m| m.fetch("month") == current.iso8601 }
    assert_nil summary.fetch("note")
    assert_equal 0, summary.fetch("income")
    assert_equal 0, summary.fetch("budgeted")
    assert_equal 0, summary.fetch("activity")
    assert_equal 0, summary.fetch("to_be_budgeted")
    assert_equal 0.0, summary.fetch("to_be_budgeted_currency")
    assert_equal "$0.00", summary.fetch("to_be_budgeted_formatted")
    assert_nil summary.fetch("age_of_money")
    assert_equal false, summary.fetch("deleted")
  end

  test "GET months computes rollups from month assignments" do
    groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    current = Date.current.beginning_of_month
    patch "/v1/plans/#{@plan.public_id}/months/#{current.iso8601}/categories/#{groceries.public_id}",
      params: { category: { budgeted: 500000 } },
      headers: auth_headers, as: :json

    get "/v1/plans/#{@plan.public_id}/months", headers: auth_headers

    assert_response :ok
    summary = response.parsed_body.fetch("data").fetch("months").find { |m| m.fetch("month") == current.iso8601 }
    assert_equal 500000, summary.fetch("budgeted")
    assert_equal 500.0, summary.fetch("budgeted_currency")
    assert_equal "$500.00", summary.fetch("budgeted_formatted")
    # Ready to Assign is income minus budgeted; no income recorded yet.
    assert_equal(-500000, summary.fetch("to_be_budgeted"))
    assert_equal(-500.0, summary.fetch("to_be_budgeted_currency"))
    assert_equal "-$500.00", summary.fetch("to_be_budgeted_formatted")
  end

  test "GET months with last_knowledge_of_server returns only changed months" do
    get "/v1/plans/#{@plan.public_id}/months", headers: auth_headers
    knowledge = response.parsed_body.fetch("data").fetch("server_knowledge")

    groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    current = Date.current.beginning_of_month
    patch "/v1/plans/#{@plan.public_id}/months/#{current.iso8601}/categories/#{groceries.public_id}",
      params: { category: { budgeted: 100000 } },
      headers: auth_headers, as: :json

    get "/v1/plans/#{@plan.public_id}/months", headers: auth_headers, params: { last_knowledge_of_server: knowledge }

    assert_response :ok
    months = response.parsed_body.fetch("data").fetch("months")
    assert_equal [ current.iso8601 ], months.map { |m| m.fetch("month") }
  end

  test "GET months/:month returns a MonthDetail with month-specific categories" do
    groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    current = Date.current.beginning_of_month
    previous = current.prev_month
    patch "/v1/plans/#{@plan.public_id}/months/#{current.iso8601}/categories/#{groceries.public_id}",
      params: { category: { budgeted: 500000 } },
      headers: auth_headers, as: :json

    get "/v1/plans/#{@plan.public_id}/months/#{previous.iso8601}", headers: auth_headers

    assert_response :ok
    detail = response.parsed_body.fetch("data").fetch("month")
    assert_equal previous.iso8601, detail.fetch("month")
    categories = detail.fetch("categories")
    groceries_month = categories.find { |c| c.fetch("id") == groceries.public_id }
    assert_equal 0, groceries_month.fetch("budgeted") # amounts are specific to the requested month
    assert_includes categories.map { |c| c.fetch("name") }, "Inflow: Ready to Assign"
  end

  test "GET months/current resolves to the current month" do
    get "/v1/plans/#{@plan.public_id}/months/current", headers: auth_headers

    assert_response :ok
    detail = response.parsed_body.fetch("data").fetch("month")
    assert_equal Date.current.beginning_of_month.iso8601, detail.fetch("month")
  end

  test "GET months/:month rejects future months with a 400" do
    future = Date.current.beginning_of_month.next_month
    get "/v1/plans/#{@plan.public_id}/months/#{future.iso8601}", headers: auth_headers

    assert_response :bad_request
    error = response.parsed_body.fetch("error")
    assert_equal "400", error.fetch("id")
    assert_equal "bad_request", error.fetch("name")
  end

  test "GET months/:month rejects invalid month formats with a 400" do
    get "/v1/plans/#{@plan.public_id}/months/not-a-month", headers: auth_headers

    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.fetch("error").fetch("name")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
