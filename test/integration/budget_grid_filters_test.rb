require "test_helper"

# #59 VIEW-FILTER-01, the two chips whose reference vectors are known.
# [reference] Only the four pinned vector observations: Money Available includes
# a category with money available and a source category (both above zero) and
# excludes a zero category and a negative one; Overspent lists only the negative one.
# [engineering] Everything else is this app's own choice, not shown parity: the
# strict >0 / <0 predicates beyond those vectors (including credit and payment
# categories, which use the same sign test), group totals summed over the shown
# rows (scoped group and global sidebar totals are not re-scoped), empty groups
# dropped, an unknown filter meaning All, hidden counts reported, the filter and
# the hidden-categories toggle composing, nothing written, other plans not
# reachable. Underfunded, Overfunded and Snoozed were not pinned by the audit and
# are not built (their chips stay disabled). Synthetic data.
class BudgetGridFiltersTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "filters@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Filter plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    # The plan starts with seeded categories; only the three below are under test.
    @budget.categories.where(internal: false).update_all(deleted: true)
    @budget.category_groups.where(internal: false).update_all(deleted: true)
    needs = @budget.category_groups.create!(name: "Needs")
    wants = @budget.category_groups.create!(name: "Wants")
    @groceries = needs.categories.create!(budget: @budget, name: "Groceries")
    @dining = needs.categories.create!(budget: @budget, name: "Dining")
    @loan = wants.categories.create!(budget: @budget, name: "Loan")
    month = Date.current.beginning_of_month
    MonthAssignment.set!(budget: @budget, category: @dining, month: month, amount: 10_000, user: @user)
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -30_000,
      "payee_name" => "Lender", "category_id" => @loan.public_id, "cleared" => "uncleared"))
  end

  def names = css_select("tr.data-table__row .budget-grid__label").map { |cell| cell.text.strip }
  def groups = css_select("tr.data-table__group .budget-grid__name").map { |cell| cell.text.strip }

  test "All lists every category and the filter chips are links except the unbuilt ones" do
    get users_budget_path(@budget.public_id)
    assert_equal %w[Dining Groceries Loan], names.sort
    assert_select ".shell-chip--active", text: "All"
    assert_select "a.shell-chip", count: 3
    %w[Underfunded Overfunded Snoozed].each { |label| assert_select "button.shell-chip[disabled]", text: label }
    assert_select "p[role=status]", text: /hidden by the/, count: 0
  end

  test "Money Available lists only categories with a positive available amount" do
    get users_budget_path(@budget.public_id, filter: "money_available")
    assert_equal %w[Dining], names
    assert_equal 1, groups.size
    assert_match(/Needs/, groups.first)
    assert_select "p[role=status]", text: /2 categories hidden by the Money Available filter/
    assert_select "a.shell-chip[aria-current=true]", text: "Money Available"
  end

  test "Overspent lists only the negative category and drops the empty group" do
    get users_budget_path(@budget.public_id, filter: "overspent")
    assert_equal %w[Loan], names
    assert_equal 1, groups.size
    assert_select "p[role=status]", text: /2 categories hidden by the Overspent filter/
  end

  test "a filtered group's totals are summed over its shown rows" do
    get users_budget_path(@budget.public_id, filter: "money_available")
    assert_select "tr.data-table__group td.data-table__money", text: "$10.00", minimum: 1
  end

  test "restoring All brings every row back and nothing was written" do
    assert_no_difference [ -> { Transaction.count }, -> { @budget.categories.count }, -> { MoneyMovement.count } ] do
      get users_budget_path(@budget.public_id, filter: "overspent")
    end
    get users_budget_path(@budget.public_id)
    assert_equal %w[Dining Groceries Loan], names.sort
  end

  test "an unknown filter means All and a filter with no matches says so" do
    get users_budget_path(@budget.public_id, filter: "bogus")
    assert_equal 3, names.size
    MonthAssignment.set!(budget: @budget, category: @dining, month: Date.current.beginning_of_month, amount: 0, user: @user)
    get users_budget_path(@budget.public_id, filter: "money_available")
    assert_empty names
    assert_select "p", text: "No categories match this filter."
  end

  test "another user's plan stays a 404 with a filter" do
    other = User.create!(email_address: "other-filters@example.com", password: "password123")
    plan = PlanLifecycle.create_plan(other, name: "Theirs")
    get users_budget_path(plan.public_id, filter: "overspent")
    assert_response :not_found
  end

  test "the filter chips and the hidden-categories link compose" do
    @groceries.update!(hidden: true)
    get users_budget_path(@budget.public_id, filter: "overspent")
    assert_select "a.budget-back-link[href=?]", users_budget_path(@budget.public_id, hidden: 1, filter: "overspent")
    get users_budget_path(@budget.public_id, filter: "overspent", hidden: 1)
    assert_select "a.shell-chip", text: "Money Available" do |links|
      assert_equal users_budget_path(@budget.public_id, filter: "money_available", hidden: 1), links.first["href"]
    end
    assert_select "a.shell-chip", text: "All" do |links|
      assert_equal users_budget_path(@budget.public_id, hidden: 1), links.first["href"]
    end
    assert_select "a.budget-back-link[href=?]", users_budget_path(@budget.public_id, filter: "overspent"), text: "Hide hidden categories"
    assert_select "p[role=status] a[href=?]", users_budget_path(@budget.public_id, hidden: 1), text: "View All"
  end

  test "a filter that hides nothing on an empty plan shows only the empty state" do
    @budget.categories.where(internal: false).update_all(deleted: true)
    get users_budget_path(@budget.public_id, filter: "overspent")
    assert_select "p", text: "No categories match this filter."
    assert_select "p[role=status]", text: /hidden by the/, count: 0
  end
end
