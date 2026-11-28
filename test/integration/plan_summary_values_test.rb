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

  test "hidden categories count in the figures, with or without the hidden toggle" do
    hidden = @dining.category_group.categories.create!(budget: @budget, name: "Hidden one", hidden: true)
    MonthAssignment.set!(budget: @budget, category: hidden, month: Date.current.beginning_of_month, amount: 5_000, user: @user)
    [ {}, { hidden: 1 } ].each do |params|
      get users_budget_path(@budget.public_id, params)
      rows = summary_rows
      assert_equal "$15.00", rows.fetch(rows.keys[1])
      assert_equal "-$15.00", rows["Available"]
      assert_equal "$0.00", rows["Left Over from Last Month"]
      assert_select ".shell-header--plan .shell-pill-amount", "$85.00"
    end
  end

  test "an amount assigned last month and unspent shows as Left Over" do
    MonthAssignment.set!(budget: @budget, category: @dining, month: Date.current.beginning_of_month.prev_month, amount: 7_000, user: @user)
    get users_budget_path(@budget.public_id)
    rows = summary_rows
    assert_equal "$7.00", rows["Left Over from Last Month"]
    assert_equal "-$13.00", rows["Available"]
  end

  test "a plan with no categories shows zero figures and the account balance as Ready to Assign" do
    @budget.categories.where(internal: false).update_all(deleted: true)
    @budget.category_groups.where(internal: false).update_all(deleted: true)
    get users_budget_path(@budget.public_id)
    assert_response :success
    rows = summary_rows
    assert_equal [ "$0.00" ] * 4, rows.values
  end

  test "the pill equals the API month Ready to Assign" do
    api = MonthSerializer.summary_as_json(@budget, Date.current.beginning_of_month).fetch(:to_be_budgeted)
    get users_budget_path(@budget.public_id)
    assert_select ".shell-header--plan .shell-pill-amount", ActionController::Base.helpers.number_to_currency(api / 1000.0)
  end

  test "Cost to Be Me totals the monthly targets, hidden categories included" do
    hidden = @dining.category_group.categories.create!(budget: @budget, name: "Hidden target", hidden: true)
    MonthlyTarget.set!(@dining, 12_000, month: Date.current.beginning_of_month)
    MonthlyTarget.set!(hidden, 8_000, month: Date.current.beginning_of_month)
    get users_budget_path(@budget.public_id)
    assert_select ".app-shell-inspector .shell-panel-title", "Cost to Be Me"
    assert_select ".app-shell-inspector .shell-panel-row", text: /Targets\s*\$20\.00/
    assert_select ".app-shell-inspector button[disabled]", text: "Enter your expected income"
  end

  test "Cost to Be Me is zero when no category has a monthly target" do
    get users_budget_path(@budget.public_id)
    assert_select ".app-shell-inspector .shell-panel-row", text: /Targets\s*\$0\.00/
  end

  test "a deleted category with a target adds nothing to Cost to Be Me" do
    gone = @dining.category_group.categories.create!(budget: @budget, name: "Gone")
    MonthlyTarget.set!(@dining, 12_000, month: Date.current.beginning_of_month)
    MonthlyTarget.set!(gone, 9_000, month: Date.current.beginning_of_month)
    gone.update!(deleted: true)
    get users_budget_path(@budget.public_id)
    assert_select ".app-shell-inspector .shell-panel-row", text: /Targets\s*\$12\.00/
  end

  test "a target of another kind adds nothing to Cost to Be Me" do
    @dining.update!(goal_type: "TB", goal_target: 50_000)
    get users_budget_path(@budget.public_id)
    assert_select ".app-shell-inspector .shell-panel-row", text: /Targets\s*\$0\.00/
  end

  def auto_rows
    css_select("#shell-auto-title").first.parent.css(".shell-panel-row").to_h { |row| [ row.at_css("span").text.strip, row.css("span").last.text.strip ] }
  end

  test "Auto-Assign shows last month's and future months' assigned amounts" do
    this_month = Date.current.beginning_of_month
    MonthAssignment.set!(budget: @budget, category: @dining, month: this_month.prev_month, amount: 7_000, user: @user)
    MonthAssignment.set!(budget: @budget, category: @loan, month: this_month.prev_month, amount: 3_000, user: @user)
    MonthAssignment.set!(budget: @budget, category: @dining, month: this_month.next_month, amount: 2_500, user: @user)
    MonthAssignment.set!(budget: @budget, category: @loan, month: this_month.next_month.next_month, amount: 500, user: @user)
    get users_budget_path(@budget.public_id)
    rows = auto_rows
    assert_equal "$10.00", rows["Assigned Last Month"]
    assert_equal "$3.00", rows["Assigned in Future Months"]
    assert_equal "\u2014", rows["Underfunded"]
  end

  test "Auto-Assign amounts are zero with nothing assigned outside this month and ignore deleted categories" do
    gone = @dining.category_group.categories.create!(budget: @budget, name: "Gone")
    MonthAssignment.set!(budget: @budget, category: gone, month: Date.current.beginning_of_month.prev_month, amount: 9_000, user: @user)
    gone.update!(deleted: true)
    get users_budget_path(@budget.public_id)
    rows = auto_rows
    assert_equal "$0.00", rows["Assigned Last Month"]
    assert_equal "$0.00", rows["Assigned in Future Months"]
  end

  def spend!(category, amount, date)
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => date.iso8601, "amount" => amount,
      "payee_name" => "Shop", "category_id" => category.public_id, "cleared" => "uncleared"))
  end

  test "Spent Last Month is last month's spending as a positive amount, not this month's or older" do
    this_month = Date.current.beginning_of_month
    spend!(@dining, -2_500, this_month.prev_month + 9)
    spend!(@loan, -1_000, this_month.prev_month.end_of_month)
    spend!(@dining, -7_000, this_month.prev_month.prev_month + 3)
    get users_budget_path(@budget.public_id)
    assert_equal "$3.50", auto_rows["Spent Last Month"]
  end

  test "Spent Last Month counts a refund against spending" do
    this_month = Date.current.beginning_of_month
    spend!(@dining, -2_500, this_month.prev_month + 9)
    spend!(@dining, 1_000, this_month.prev_month + 12)
    get users_budget_path(@budget.public_id)
    assert_equal "$1.50", auto_rows["Spent Last Month"]
  end

  test "Spent Last Month is zero with nothing spent last month" do
    get users_budget_path(@budget.public_id)
    assert_equal "$0.00", auto_rows["Spent Last Month"]
  end

  test "in January the Last Month rows read December of the year before" do
    travel_to Date.new(2027, 1, 15) do
      MonthAssignment.set!(budget: @budget, category: @dining, month: Date.new(2026, 12, 1), amount: 6_000, user: @user)
      spend!(@dining, -2_000, Date.new(2026, 12, 20))
      spend!(@dining, -9_000, Date.new(2026, 11, 20))
      get users_budget_path(@budget.public_id)
      rows = auto_rows
      assert_equal "$6.00", rows["Assigned Last Month"]
      assert_equal "$2.00", rows["Spent Last Month"]
    end
  end

  test "the Last Month rows leave out hidden categories and categories in hidden groups" do
    this_month = Date.current.beginning_of_month
    hidden = @dining.category_group.categories.create!(budget: @budget, name: "Hidden one", hidden: true)
    tucked = @budget.category_groups.create!(name: "Tucked away", hidden: true).categories.create!(budget: @budget, name: "Tucked")
    MonthAssignment.set!(budget: @budget, category: @dining, month: this_month.prev_month, amount: 6_000, user: @user)
    [ hidden, tucked ].each do |category|
      MonthAssignment.set!(budget: @budget, category: category, month: this_month.prev_month, amount: 4_000, user: @user)
      spend!(category, -3_000, this_month.prev_month + 5)
    end
    spend!(@dining, -2_000, this_month.prev_month + 5)
    [ {}, { hidden: 1 } ].each do |params|
      get users_budget_path(@budget.public_id, params)
      rows = auto_rows
      assert_equal "$6.00", rows["Assigned Last Month"]
      assert_equal "$2.00", rows["Spent Last Month"]
    end
  end
end
