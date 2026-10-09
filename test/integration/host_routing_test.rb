require "test_helper"

class HostRoutingTest < ActionDispatch::IntegrationTest
  test "public root renders landing page and links to app subdomain" do
    host! "www.budgetify.test"
    get "/"

    assert_response :success
    assert_select "h1", "A plan for every dollar."
    assert_select "a[href=?]", "http://app.budgetify.test/"
  end

  test "signed-out app root redirects to canonical sign-in path" do
    host! "app.budgetify.test"
    get "/"

    assert_redirected_to users_sign_in_path
    follow_redirect!

    assert_response :success
    assert_select "form[action=?]", login_user_path
  end

  test "API login syncs catalog and routes to the budget selector" do
    host! "app.budgetify.test"
    user = users(:one)

    post "/loginUser", params: { email: user.email_address, password: "password" }, as: :json

    assert_response :ok
    get "/"

    assert_redirected_to users_budgets_path
    follow_redirect!

    assert_response :success
    assert_select "h1", "Choose a budget."
    assert_select ".budget-empty-state", /No budgets are available yet/
  end

  test "catalog request returns the logged-in user's catalog before navigation" do
    host! "app.budgetify.test"
    user = users(:one)
    budget = user.budgets.create!(name: "Household")

    post "/loginUser", params: { email: user.email_address, password: "password" }, as: :json

    assert_response :ok
    token = response.parsed_body.fetch("session_token")
    get "/api/v1/catalog", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :success
    assert_equal({ "data" => { "budgets" => [ { "id" => budget.public_id, "name" => "Household" } ] } }, response.parsed_body)
  end
end
