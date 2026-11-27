require "test_helper"

# The register page shows Cleared + Uncleared = Working for the whole account,
# the same line and consistency rule as the plan-page register header.
# [engineering] checks on synthetic data. Nothing here is a reference number.
class RegisterBalanceLineTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "balanceline@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Balance plan")
  end

  def list_path(account, **params) = users_budget_account_transactions_path(@budget.public_id, account.public_id, **params)

  def add_row(account, amount:, cleared:, payee: "Shop")
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => account.public_id, "date" => Date.current.iso8601, "amount" => amount, "payee_name" => payee, "cleared" => cleared))
  end

  test "the line follows real rows, and reconciled rows count as cleared" do
    account = @budget.accounts.create!(name: "Checking", type: "checking")
    add_row(account, amount: 100_000, cleared: "cleared")
    add_row(account, amount: -30_000, cleared: "reconciled")
    add_row(account, amount: -12_500, cleared: "uncleared")

    get list_path(account)

    assert_response :success
    summary = css_select(".register-page .shell-balance-summary").first.text.squish
    assert_match(/Cleared \$70\.00 \+ Uncleared -\$12\.50 = Working \$57\.50/, summary)
    assert_select ".register-page .shell-balance-summary button", count: 0
    assert_select ".register-page .shell-balance-summary[aria-label='Balance summary']", count: 1
  end

  test "filters and search do not change the line" do
    account = @budget.accounts.create!(name: "Checking", type: "checking")
    add_row(account, amount: 50_000, cleared: "cleared", payee: "Alpha")
    add_row(account, amount: -20_000, cleared: "uncleared", payee: "Beta")

    get list_path(account, q: "Alpha")

    assert_response :success
    assert_equal 1, css_select("td[data-label=Payee]").size
    assert_match(/Cleared \$50\.00 \+ Uncleared -\$20\.00 = Working \$30\.00/, css_select(".register-page .shell-balance-summary").first.text.squish)
  end

  test "dashes replace the parts when they do not add up to the stored balance" do
    account = @budget.accounts.create!(name: "Visa", type: "creditCard", balance: -25_000)

    get list_path(account)

    assert_response :success
    assert_match(/Cleared — \+ Uncleared — = Working -\$25\.00/, css_select(".register-page .shell-balance-summary").first.text.squish)
  end

  test "an account with no rows shows zeros" do
    account = @budget.accounts.create!(name: "Empty", type: "checking")

    get list_path(account)

    assert_response :success
    assert_match(/Cleared \$0\.00 \+ Uncleared \$0\.00 = Working \$0\.00/, css_select(".register-page .shell-balance-summary").first.text.squish)
  end
end
