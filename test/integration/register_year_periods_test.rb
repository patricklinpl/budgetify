require "test_helper"

# Register year presets seen in the reference View menu. [reference]
class RegisterYearPeriodsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "years@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Years plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    today = Date.current
    { "This year row" => today.beginning_of_year, "Last year row" => today.beginning_of_year - 1.day,
      "Two years row" => today.beginning_of_year - 1.year - 1.day }.each do |memo, date|
      @account.transactions.create!(budget: @budget, date: date, amount: -100, memo: memo, cleared: "uncleared")
    end
  end

  def list(period) = get(users_budget_account_transactions_path(@budget.public_id, @account.public_id, period: period))

  test "this year lists only this calendar year" do
    list("this_year")
    assert_select "td", text: "This year row"
    assert_select "td", text: "Last year row", count: 0
    assert_select "td", text: "Two years row", count: 0
    assert_select "a[aria-current=true]", text: "This year"
  end

  test "last year lists only the previous calendar year" do
    list("last_year")
    assert_select "td", text: "Last year row"
    assert_select "td", text: "This year row", count: 0
    assert_select "td", text: "Two years row", count: 0
  end
end
