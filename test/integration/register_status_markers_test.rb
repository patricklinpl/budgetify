require "test_helper"

# Register flag column and cleared/approval markers. [engineering]
class RegisterStatusMarkersTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "markers@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Markers plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
  end

  def list = get(users_budget_account_transactions_path(@budget.public_id, @account.public_id, reconciled: "1"))

  test "flag, cleared marker and unapproved chip render beside the existing text" do
    @account.transactions.create!(budget: @budget, date: Date.current, amount: -500, cleared: "reconciled", approved: true, flag_color: "red", flag_name: "Check this")
    @account.transactions.create!(budget: @budget, date: Date.current, amount: -700, cleared: "uncleared", approved: false)
    list
    assert_response :success
    assert_select "span.register-flag--red[aria-label='Check this']", 1
    assert_select "td.register-cleared--reconciled", 1
    assert_select "td.register-cleared--uncleared", 1
    assert_select "span.register-chip", text: "Unapproved", count: 1
    assert_select "td[data-label=Status]", text: /Reconciled/
  end
end
