require "test_helper"

class AppShellTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "empty plan renders the shell with an explicit empty state" do
    budget = @user.budgets.create!(name: "Household")

    get users_budget_path(budget.public_id)

    assert_response :success
    assert_select ".app-shell-sidebar .app-shell-plan-name", "Household"
    assert_select ".app-shell-nav a", "Plan"
    assert_select ".app-shell-empty", "No accounts yet."
    assert_select ".app-shell-account-group", count: 0
  end

  test "sidebar groups accounts with subtotals and flags negative balances" do
    budget = @user.budgets.create!(name: "Household")
    budget.accounts.create!(name: "Checking", type: "checking", balance: 1_500_000)
    budget.accounts.create!(name: "Savings", type: "savings", balance: 500_000)
    budget.accounts.create!(name: "Visa", type: "creditCard", balance: -25_000)

    get users_budget_path(budget.public_id)

    assert_response :success
    names = css_select(".app-shell-account-group-name").map { |n| n.text.strip }
    assert_equal %w[CASH CREDIT], names
    assert_select ".app-shell-account-group-header", /\$2,000\.00/
    assert_select ".app-shell-account", /Checking/
    assert_select ".app-shell-account .money--negative", "-$25.00"
  end
end
