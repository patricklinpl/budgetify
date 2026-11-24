require "test_helper"

class BudgetGridTest < ActionDispatch::IntegrationTest
  EXPRESSIONS = { "100" => 100_000, "10+5*2" => 20_000, "(10+5)*2" => 30_000, "-5" => -5_000, "12.345" => 12_345, "10/4" => 2_500, " 7 + 3 " => 10_000 }.freeze
  INVALID = [ "", "abc", "10+", "1/0", "1.2345", "((1)", "1 2", "$5", "1e3", "10/3" ].freeze

  test "expressions evaluate with precedence and exact amounts" do
    EXPRESSIONS.each { |text, milli| assert_equal milli, AssignedExpression.parse(text).milliunits, text }
  end

  test "invalid expressions are rejected with a message, never zero" do
    INVALID.each do |text|
      result = AssignedExpression.parse(text)
      assert_nil result.milliunits, text.inspect
      assert result.error.present?, text.inspect
    end
  end

  test "grid lists categories and assigns from an expression" do
    user, budget, category = sign_in_with_category
    get users_budget_path(budget.public_id)
    assert_response :success
    assert_select "table[aria-label='Budget grid']"
    assert_select "td", text: /Groceries/

    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "10+5*2" } }
    assert_redirected_to users_budget_path(budget.public_id)
    assert_equal 20_000, category.reload.month_category_for(Date.current.beginning_of_month).budgeted
    assert_equal 1, budget.money_movements.count
  end

  test "an invalid expression changes nothing and says so" do
    user, budget, category = sign_in_with_category
    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "10+" } }
    follow_redirect!
    assert_select "[role=alert]", text: /Nothing was changed/
    assert_equal 0, category.reload.month_category_for(Date.current.beginning_of_month).budgeted.to_i
    assert_equal 0, budget.money_movements.count
  end

  test "rename and hide, and other users cannot reach a category" do
    user, budget, category = sign_in_with_category
    patch users_budget_category_path(budget.public_id, category.public_id), params: { category: { name: "Food", hidden: "true" } }
    assert_equal [ "Food", true ], [ category.reload.name, category.hidden ]
    get users_budget_path(budget.public_id)
    assert_select "td", text: /Food/, count: 0
    get users_budget_path(budget.public_id, hidden: 1)
    assert_select "td", text: /Food \(hidden\)/

    patch users_budget_category_path(budget.public_id, category.public_id), params: { category: { name: " " } }
    assert_response :unprocessable_entity
    assert_equal "Food", category.reload.name

    other = User.create!(email_address: "other-grid@example.com", password: "password123")
    other_budget = PlanLifecycle.create_plan(other, name: "Theirs")
    get edit_users_budget_category_path(other_budget.public_id, category.public_id)
    assert_response :not_found
  end

  test "delete with assigned money needs a decision and a replacement moves it" do
    user, budget, category = sign_in_with_category
    other = budget.category_groups.find_by!(name: "Everyday").categories.create!(budget: budget, name: "Fun")
    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "50" } }

    delete users_budget_category_path(budget.public_id, category.public_id)
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Choose a replacement/
    assert_not category.reload.deleted

    delete users_budget_category_path(budget.public_id, category.public_id), params: { replacement_id: other.public_id }
    assert_redirected_to users_budget_path(budget.public_id)
    assert category.reload.deleted
    assert_equal 50_000, other.month_category_for(Date.current.beginning_of_month).budgeted
  end

  private
    def sign_in_with_category
      user = User.create!(email_address: "grid@example.com", password: "password123")
      post session_path, params: { email_address: user.email_address, password: "password123" }
      budget = PlanLifecycle.create_plan(user, name: "Grid plan")
      group = budget.category_groups.create!(name: "Everyday")
      category = group.categories.create!(budget: budget, name: "Groceries")
      [ user, budget, category ]
    end
end
