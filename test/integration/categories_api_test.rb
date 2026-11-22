require "test_helper"

# Request-level checks for the categories endpoints (issue #29):
# GET/POST /v1/plans/:plan_id/categories, GET/PATCH .../categories/:category_id,
# POST/PATCH .../category_groups, GET/PATCH .../months/:month/categories/:category_id.
class CategoriesApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "categories@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/categories"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
  end

  test "plans get a built-in internal Inflow category group on create" do
    internal_group = @plan.category_groups.find_by(internal: true)

    assert internal_group.present?
    assert_equal "Internal Master Category", internal_group.name
    inflow = internal_group.categories.find_by(internal: true)
    assert inflow.present?
    assert_equal "Inflow: Ready to Assign", inflow.name
  end

  test "GET categories lists groups with embedded categories and server_knowledge" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")

    get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    groups = data.fetch("category_groups")
    everyday = groups.find { |g| g.fetch("name") == "Everyday Expenses" }
    assert_equal false, everyday.fetch("hidden")
    assert_equal false, everyday.fetch("internal")
    listed = everyday.fetch("categories").map { |c| c.fetch("name") }
    assert_includes listed, "Groceries"
    serialized = everyday.fetch("categories").find { |c| c.fetch("id") == category.public_id }
    assert_equal category.public_id, serialized.fetch("id")
    assert_equal "Everyday Expenses", serialized.fetch("category_group_name")
    assert_equal 0, serialized.fetch("budgeted")
    assert_equal 0.0, serialized.fetch("budgeted_currency")
    assert_equal "$0.00", serialized.fetch("budgeted_formatted")
    assert_equal 0, serialized.fetch("activity")
    assert_equal 0, serialized.fetch("balance")
    assert_nil serialized.fetch("goal_type")
    assert_equal false, serialized.fetch("deleted")
  end

  test "POST categories creates a category and defaults the goal type" do
    assert_difference -> { @group.categories.count } => 1 do
      post "/v1/plans/#{@plan.public_id}/categories",
        params: { category: { category_group_id: @group.public_id, name: "Rent", note: "Due monthly", goal_target: 1500000 } },
        headers: auth_headers, as: :json
    end

    assert_response :created
    category = response.parsed_body.fetch("data").fetch("category")
    assert_equal "Rent", category.fetch("name")
    assert_equal "Due monthly", category.fetch("note")
    assert_equal 1500000, category.fetch("goal_target")
    assert_equal 1500.0, category.fetch("goal_target_currency")
    assert_equal "NEED", category.fetch("goal_type")
    assert category.fetch("goal_creation_month").present?
  end

  test "POST categories rejects an internal group" do
    internal_group = @plan.category_groups.find_by(internal: true)

    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: internal_group.public_id, name: "Nope" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
    assert_equal "400", response.parsed_body.fetch("error").fetch("id")
  end

  test "GET category returns the category with current-month amounts" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")

    get "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal category.public_id, data.fetch("category").fetch("id")
  end

  test "GET category returns 404.2 for unknown ids" do
    get "/v1/plans/#{@plan.public_id}/categories/00000000-0000-0000-0000-000000000000", headers: auth_headers

    assert_response :not_found
    error = response.parsed_body.fetch("error")
    assert_equal "404.2", error.fetch("id")
    assert_equal "resource_not_found", error.fetch("name")
  end

  test "PATCH category renames, moves groups and clears goals" do
    other_group = @plan.category_groups.create!(name: "Savings")
    category = @group.categories.create!(budget: @plan, name: "Groceries", goal_target: 50000, goal_type: "NEED")

    patch "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}",
      params: { category: { name: "Food", category_group_id: other_group.public_id, goal_target: nil } },
      headers: auth_headers, as: :json

    assert_response :ok
    data = response.parsed_body.fetch("data").fetch("category")
    assert_equal "Food", data.fetch("name")
    assert_equal other_group.public_id, data.fetch("category_group_id")
    assert_nil data.fetch("goal_target")
    assert_nil data.fetch("goal_type")
  end

  test "PATCH category rejects moves into the internal group" do
    internal_group = @plan.category_groups.find_by(internal: true)
    category = @group.categories.create!(budget: @plan, name: "Groceries")

    patch "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}",
      params: { category: { category_group_id: internal_group.public_id } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "POST category_groups creates a group" do
    assert_difference -> { @plan.category_groups.count } => 1 do
      post "/v1/plans/#{@plan.public_id}/category_groups",
        params: { category_group: { name: "Giving" } },
        headers: auth_headers, as: :json
    end

    assert_response :created
    data = response.parsed_body.fetch("data")
    assert_equal "Giving", data.fetch("category_group").fetch("name")
    assert data.key?("server_knowledge")
  end

  test "POST category_groups enforces the 50 character name limit" do
    post "/v1/plans/#{@plan.public_id}/category_groups",
      params: { category_group: { name: "x" * 51 } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "PATCH category_groups renames a group and returns its category ids" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")

    patch "/v1/plans/#{@plan.public_id}/category_groups/#{@group.public_id}",
      params: { category_group: { name: "Everyday" } },
      headers: auth_headers, as: :json

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "Everyday", data.fetch("category_group").fetch("name")
    assert_includes data.fetch("category_group_ids"), category.public_id
  end

  test "GET month category returns amounts for the given month" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")
    month = Date.current.beginning_of_month
    category.month_categories.create!(month: month, budgeted: 400000)

    get "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data").fetch("category")
    assert_equal 400000, data.fetch("budgeted")
    assert_equal 400000, data.fetch("balance")
  end

  test "GET month category accepts current as the month" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")

    get "/v1/plans/#{@plan.public_id}/months/current/categories/#{category.public_id}", headers: auth_headers

    assert_response :ok
  end

  test "GET month category rejects future months" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")
    future = Date.current.beginning_of_month.next_month

    get "/v1/plans/#{@plan.public_id}/months/#{future.iso8601}/categories/#{category.public_id}", headers: auth_headers

    assert_response :bad_request
    assert_equal "400", response.parsed_body.fetch("error").fetch("id")
  end

  test "PATCH month category assigns the budgeted amount" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")
    month = Date.current.beginning_of_month

    patch "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}",
      params: { category: { budgeted: 250000 } },
      headers: auth_headers, as: :json

    assert_response :ok
    data = response.parsed_body.fetch("data").fetch("category")
    assert_equal 250000, data.fetch("budgeted")
    assert_equal 250000, data.fetch("balance")
    assert_equal 250.0, data.fetch("budgeted_currency")
  end

  test "PATCH month category rejects the internal Inflow category" do
    inflow = @plan.categories.find_by(internal: true)
    month = Date.current.beginning_of_month

    patch "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{inflow.public_id}",
      params: { category: { budgeted: 1000 } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "category write responses include server_knowledge (spec: SaveCategoryResponse)" do
    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: @group.public_id, name: "Groceries" } },
      headers: auth_headers, as: :json

    assert_response :created
    assert_equal @plan.reload.server_knowledge, response.parsed_body.fetch("data").fetch("server_knowledge")
    category_id = response.parsed_body.fetch("data").fetch("category").fetch("id")

    patch "/v1/plans/#{@plan.public_id}/categories/#{category_id}",
      params: { category: { name: "Food" } },
      headers: auth_headers, as: :json

    assert_response :ok
    assert_equal @plan.reload.server_knowledge, response.parsed_body.fetch("data").fetch("server_knowledge")

    patch "/v1/plans/#{@plan.public_id}/months/current/categories/#{category_id}",
      params: { category: { budgeted: 350_000 } },
      headers: auth_headers, as: :json

    assert_response :ok
    assert_equal @plan.reload.server_knowledge, response.parsed_body.fetch("data").fetch("server_knowledge")
  end

  test "POST categories accepts goal_frequency and configures a recurring NEED target" do
    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: @group.public_id, name: "Groceries", goal_target: 400_000, goal_frequency: "monthly" } },
      headers: auth_headers, as: :json

    assert_response :created
    category = response.parsed_body.fetch("data").fetch("category")
    assert_equal "NEED", category.fetch("goal_type")
    assert_equal 1, category.fetch("goal_cadence")
    assert_equal 1, category.fetch("goal_cadence_frequency")
    assert_equal 400_000, category.fetch("goal_target")
    assert_nil category.fetch("goal_target_date")
  end

  test "POST categories rejects goal_frequency without a goal_target or combined with a goal_target_date" do
    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: @group.public_id, name: "Groceries", goal_frequency: "monthly" } },
      headers: auth_headers, as: :json

    assert_response :bad_request

    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: @group.public_id, name: "Groceries", goal_target: 400_000, goal_target_date: "2027-06-01", goal_frequency: "yearly" } },
      headers: auth_headers, as: :json

    assert_response :bad_request

    post "/v1/plans/#{@plan.public_id}/categories",
      params: { category: { category_group_id: @group.public_id, name: "Groceries", goal_target: 400_000, goal_frequency: "fortnightly" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "PATCH category clearing the goal target clears the remaining goal fields" do
    category = @group.categories.create!(budget: @plan, name: "Groceries", goal_type: "NEED",
      goal_target: 400_000, goal_cadence: 1, goal_cadence_frequency: 1, goal_needs_whole_amount: false,
      goal_creation_month: Date.current.beginning_of_month)

    patch "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}",
      params: { category: { goal_target: nil } },
      headers: auth_headers, as: :json

    assert_response :ok
    serialized = response.parsed_body.fetch("data").fetch("category")
    assert_nil serialized.fetch("goal_target")
    assert_nil serialized.fetch("goal_type")
    assert_nil serialized.fetch("goal_cadence")
    assert_nil serialized.fetch("goal_cadence_frequency")
    assert_nil serialized.fetch("goal_needs_whole_amount")
    assert_nil serialized.fetch("goal_day")
  end

  test "GET categories supports last_knowledge_of_server delta requests" do
    category = @group.categories.create!(budget: @plan, name: "Groceries")
    knowledge = @plan.reload.server_knowledge

    get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers, params: { last_knowledge_of_server: knowledge }
    assert_response :ok
    groups = response.parsed_body.fetch("data").fetch("category_groups")
    assert_empty groups

    category.update!(name: "Food")
    get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers, params: { last_knowledge_of_server: knowledge }

    assert_response :ok
    groups = response.parsed_body.fetch("data").fetch("category_groups")
    assert_equal 1, groups.size
    assert_equal "Food", groups.first.fetch("categories").first.fetch("name")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
