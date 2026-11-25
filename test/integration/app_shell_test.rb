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

  test "plan view renders header shell, inspector panels and sidebar sign out" do
    budget = @user.budgets.create!(name: "Household")

    get users_budget_path(budget.public_id)

    assert_response :success
    assert_select "h1", "Household"
    assert_select ".shell-header--plan .shell-month-label"
    assert_select ".shell-header--plan .shell-pill", /Ready to Assign/
    assert_select ".shell-header--plan .shell-chip", count: 6
    assert_select ".shell-header--plan .shell-toolbar button", text: "Add Category Group"
    assert_select ".app-shell-inspector .shell-panel", count: 2
    assert_select ".app-shell-inspector .shell-panel-title", /Summary/
    assert_select ".app-shell-inspector .shell-panel-title", "Auto-Assign"
    assert_select ".app-shell-sidebar form[action='#{session_path}'] button", "Sign out"
    assert_select ".app-shell-nav-item[aria-disabled='true']", count: 1, text: "All Accounts"
    assert_select ".app-shell-nav a", text: "Reflect"
    assert_select ".app-shell-nav a[aria-current='page']", "Plan"
  end

  test "selected account renders register header shell and selected state" do
    budget = @user.budgets.create!(name: "Household")
    checking = budget.accounts.create!(name: "Checking", type: "checking", balance: 1_500_000, cleared_balance: 1_000_000, uncleared_balance: 500_000)
    budget.accounts.create!(name: "Savings", type: "savings", balance: 500_000)

    get users_budget_path(budget.public_id, account: checking.public_id)

    assert_response :success
    assert_select "h1", /Checking/
    assert_select ".shell-header--register .shell-balance-summary", /Cleared\s+\$1,000\.00.*Uncleared\s+\$500\.00.*Working\s+\$1,500\.00/m
    assert_select ".shell-header--register .shell-search"
    assert_select ".shell-header--register button", text: "Reconcile"
    assert_select ".shell-header--plan", count: 0
    assert_select ".app-shell-inspector", count: 0
    assert_select "a.app-shell-account--selected[aria-current='page']", /Checking/
    assert_select ".app-shell-nav a[aria-current]", count: 0
    assert_select "a.app-shell-account[href*='account=']", count: 2
  end

  test "account from another plan or unknown id is not found" do
    budget = @user.budgets.create!(name: "Household")
    other = @user.budgets.create!(name: "Other")
    foreign = other.accounts.create!(name: "Foreign", type: "checking", balance: 1000)

    get users_budget_path(budget.public_id, account: foreign.public_id)
    assert_response :not_found

    get users_budget_path(budget.public_id, account: "missing")
    assert_response :not_found
  end

  test "register summary shows dashes when cleared and uncleared do not add up to the balance" do
    budget = @user.budgets.create!(name: "Household")
    visa = budget.accounts.create!(name: "Visa", type: "creditCard", balance: -25_000)

    get users_budget_path(budget.public_id, account: visa.public_id)

    assert_response :success
    summary = css_select(".shell-balance-summary").first.text.squish
    assert_match(/Cleared — \+ Uncleared — = Working -\$25\.00/, summary)
  end
end
