require "test_helper"

class CatalogAndBudgetSelectionTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @session = @user.sessions.create!
    @session_token = @session.generate_api_token!
  end

  test "catalog returns only the authenticated user's real budgets" do
    budget = @user.budgets.create!(name: "Household")
    users(:two).budgets.create!(name: "Private budget")

    get "/api/v1/catalog", headers: authorization_header(@session_token)

    assert_response :success
    assert_equal({
      "data" => {
        "budgets" => [ { "id" => budget.public_id, "name" => "Household" } ]
      }
    }, response.parsed_body)
  end

  test "catalog returns an empty list when no budgets exist" do
    get "/api/v1/catalog", headers: authorization_header(@session_token)

    assert_response :success
    assert_equal({ "data" => { "budgets" => [] } }, response.parsed_body)
  end

  test "catalog requires bearer authentication" do
    get "/api/v1/catalog"

    assert_response :unauthorized
  end

  test "budget selector requires a browser session" do
    get "/users/budgets"

    assert_redirected_to users_sign_in_path
  end

  test "signed-in user can list and select only owned budgets" do
    budget = @user.budgets.create!(name: "Household")
    other_budget = users(:two).budgets.create!(name: "Private budget")
    sign_in_as(@user)

    get "/users/budgets"

    assert_response :success
    assert_select "a[href=?]", users_budget_path(budget.public_id)
    refute_includes response.body, other_budget.name

    get users_budget_path(budget.public_id)

    assert_response :success
    assert_select "h1", "Household"

    get users_budget_path(other_budget.public_id)

    assert_response :not_found
  end

  private

  def authorization_header(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
