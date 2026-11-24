require "test_helper"

class BudgetGridTest < ActionDispatch::IntegrationTest
  EXPRESSIONS = { "100" => 100_000, "10+5*2" => 20_000, "(10+5)*2" => 30_000, "-5" => -5_000, "12.34" => 12_340, "10/4" => 2_500,
                  " 7 + 3 " => 10_000, "$1,234.56" => 1_234_560, ".5" => 500, "+4" => 4_000, "0.1+0.2" => 300 }.freeze
  INVALID = [ "", "abc", "10+", "1/0", "1.2345", "12.345", "0.004", "((1)", "$5x", "1e3", "10/3", "1,5", "12,34", "1,2345", "1.", "99999999999999999" ].freeze

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

  test "precision is whole cents whatever the plan display digits" do
    assert_equal "Use at most 2 decimal places (whole cents)", AssignedExpression.parse("12.345").error
    assert_equal 12_340, AssignedExpression.parse("12.34").milliunits
  end

  test "a yen plan shows its own format, keeps whole-cent arithmetic and prints the exact value" do
    user, budget, category = sign_in_with_category
    budget.update!(currency_format: budget.currency_format.as_json.merge("decimal_digits" => 0, "currency_symbol" => "\u00a5", "symbol_first" => true))
    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "1200" } }
    follow_redirect!
    assert_select "td", text: /\u00a51,200/
    assert_select "input[name='assigned[amount]'][value='1200.00']"
    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "1200.5" } }
    assert_equal 1_200_500, category.reload.month_category_for(Date.current.beginning_of_month).budgeted
    get users_budget_path(budget.public_id)
    assert_select ".budget-grid__exact", text: "exact 1200.500", minimum: 3
  end

  test "values finer than the plan digits show their exact amount, never silently rounded" do
    user, budget, category = sign_in_with_category
    MonthAssignment.set!(budget: budget, category: category, month: Date.current.beginning_of_month, amount: 12_345, user: user)
    get users_budget_path(budget.public_id)
    assert_select ".budget-grid__exact", text: "exact 12.345", minimum: 3
    assert_select "input[name='assigned[amount]'][value='12.345']"
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

  test "an invalid expression keeps the typed text, shows an inline linked error and saves nothing" do
    user, budget, category = sign_in_with_category
    patch assign_users_budget_category_path(budget.public_id, category.public_id), params: { assigned: { amount: "10+" } }
    assert_response :unprocessable_entity
    input = css_select("input#assigned_#{category.public_id}").first
    assert_equal "10+", input["value"]
    assert_equal "true", input["aria-invalid"]
    assert_equal "assigned_#{category.public_id}-err", input["aria-describedby"]
    assert_select "span#assigned_#{category.public_id}-err[role=alert]", text: /Nothing was changed/
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
      sign_in_as(user)
      budget = PlanLifecycle.create_plan(user, name: "Grid plan")
      group = budget.category_groups.create!(name: "Everyday")
      category = group.categories.create!(budget: budget, name: "Groceries")
      [ user, budget, category ]
    end
end
