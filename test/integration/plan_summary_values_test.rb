require "test_helper"

# Plan header Ready to Assign and the Summary panel show real figures.
# [reference] The reference Summary lists Left Over from Last Month, Assigned,
# Activity and Available; the header shows Ready to Assign.
# [engineering] The sums, the remainder rule for Left Over, and the filter not
# changing them are this app's own choices. Synthetic data.
class PlanSummaryValuesTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "summary@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Summary plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    @budget.categories.where(internal: false).update_all(deleted: true)
    @budget.category_groups.where(internal: false).update_all(deleted: true)
    group = @budget.category_groups.create!(name: "Needs")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    @loan = group.categories.create!(budget: @budget, name: "Loan")
    MonthAssignment.set!(budget: @budget, category: @dining, month: Date.current.beginning_of_month, amount: 10_000, user: @user)
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -30_000,
      "payee_name" => "Lender", "category_id" => @loan.public_id, "cleared" => "uncleared"))
  end

  def summary_rows
    css_select(".app-shell-inspector .shell-panel-row").first(4).to_h { |row| [ row.at_css("dt").text.strip, row.at_css("dd").text.strip ] }
  end

  test "pill and Summary panel show the month figures" do
    get users_budget_path(@budget.public_id)
    assert_select ".shell-header--plan .shell-pill-amount", "$90.00"
    rows = summary_rows
    assert_equal "$0.00", rows["Left Over from Last Month"]
    assert_equal "$10.00", rows.fetch(rows.keys[1])
    assert_equal "-$30.00", rows["Activity"]
    assert_equal "-$20.00", rows["Available"]
  end

  test "a chip filter does not change the Summary figures" do
    get users_budget_path(@budget.public_id, filter: "overspent")
    assert_equal "-$20.00", summary_rows["Available"]
    assert_select ".shell-header--plan .shell-pill-amount", "$90.00"
  end

  test "the register view has no plan pill" do
    get users_budget_path(@budget.public_id, account: @account.public_id)
    assert_select ".shell-header--plan .shell-pill-amount", count: 0
  end
end
