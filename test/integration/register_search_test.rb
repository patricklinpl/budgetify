require "test_helper"

# #62 slice 1 (REG-01 payee search, REG-DATE-01 This month / Last month).
# [reference T] Search applies on Enter (a GET form, never while typing), the
# opening balance row hides under a payee search with a hidden-by-filters notice,
# clearing the search restores it, and Last month filters to the previous month with
# a notice. [engineering] Case-insensitive substring match on the payee name only,
# literal % and _, a 200 character cap, an unknown period means All dates. Custom
# bounds, other fields, search syntax and combined predicates were not tested in the
# reference and are not built. Synthetic data only.
class RegisterSearchTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.utc(2026, 11, 23, 12, 0, 0)
    @user = User.create!(email_address: "search@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Search plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Savings", "type" => "savings", "balance" => 45_000 })
    add("2026-11-20", "Corner Shop", "5.00")
    add("2026-11-21", "Bakery_Main", "3.00")
    add("2026-10-28", "Corner Shop", "7.00")
    add("2026-11-22", "100% Juice", "2.00")
  end

  teardown { travel_back }

  def list(**query) = users_budget_account_transactions_path(@budget.public_id, @account.public_id, **query)

  def add(date, payee, outflow)
    post users_budget_account_transactions_path(@budget.public_id, @account.public_id),
      params: { transaction: { date: date, payee: payee, category_id: "", memo: "", outflow: outflow, inflow: "" } }
    assert_response :redirect
  end

  def payees
    css_select("tbody tr td[data-label=Payee]").map { |cell| cell.text.strip }
  end

  test "no filter lists every row, including the opening balance" do
    get list
    assert_equal [ "Bakery_Main", "100% Juice", "Corner Shop", "Corner Shop", "Starting Balance" ].sort, payees.sort
    assert_select ".register-page__hidden", text: /hidden by filters/, count: 0
  end

  test "a payee search lists matching rows, hides the opening balance and says how many are hidden" do
    get list(q: "corner")
    assert_equal [ "Corner Shop", "Corner Shop" ], payees
    assert_select ".register-page__hidden", text: /3 transactions hidden by filters/
    assert_select "input[type=search][name=q][value=corner]"
  end

  test "clearing the search restores every row" do
    get list(q: "corner")
    assert_select "a", text: "Clear search"
    get list
    assert_equal 5, payees.size
  end

  test "the search is a GET form that submits on Enter and carries the other filters" do
    get list(q: "shop", period: "this_month", reconciled: "1")
    assert_select "form[method=get][role=search]" do
      assert_select "input[type=hidden][name=period][value=this_month]"
      assert_select "input[type=hidden][name=reconciled][value='1']"
      assert_select "input[type=submit][value=Search]"
    end
  end

  test "matching is a case-insensitive substring and % and _ are literal" do
    get list(q: "CORNER SH")
    assert_equal 2, payees.size
    get list(q: "y_m")
    assert_equal [ "Bakery_Main" ], payees.select { |name| name.include?("_") }
    get list(q: "_")
    assert_equal [ "Bakery_Main" ], payees
    get list(q: "%")
    assert_equal [ "100% Juice" ], payees
    get list(q: "no such payee")
    assert_empty payees
    assert_select "p", text: "No transactions match the current filters."
    assert_select ".register-page__hidden", text: /5 transactions hidden by filters/
  end

  test "a blank or whitespace search filters nothing and a very long one is capped" do
    get list(q: "   ")
    assert_equal 5, payees.size
    get list(q: "x" * 5000)
    assert_response :success
    assert_select "input[type=search][name=q]" do |inputs|
      assert_equal 200, inputs.first["value"].length
    end
  end

  test "This month and Last month filter by the calendar month and report the hidden rows" do
    get list(period: "last_month")
    assert_equal [ "Corner Shop" ], payees
    assert_select ".register-page__hidden", text: /4 transactions hidden by filters/
    get list(period: "this_month")
    assert_equal 4, payees.size
    assert_select ".register-page__hidden", text: /1 transaction hidden by filters/
    assert_select "nav[aria-label=Dates] a[aria-current=true]", text: "This month"
    get list(period: "all")
    assert_equal 5, payees.size
  end

  test "Last month with nothing in it shows the empty filtered message and the notice" do
    @account.transactions.where("date < ?", "2026-11-01").where(opening_balance: false).destroy_all
    get list(period: "last_month")
    assert_empty payees
    assert_select "p", text: "No transactions match the current filters."
  end

  test "an unknown period means all dates" do
    get list(period: "last_century")
    assert_equal 5, payees.size
    assert_select "nav[aria-label=Dates] a[aria-current=true]", text: "All dates"
  end

  test "search and period combine, and Show Reconciled keeps them" do
    get list(q: "corner", period: "last_month")
    assert_equal [ "Corner Shop" ], payees
    assert_select "a[href*='reconciled=1'][href*='q=corner'][href*='period=last_month']", text: "Show Reconciled"
  end

  test "filtering writes nothing and changes no balance" do
    balance = @account.reload.balance
    assert_no_difference -> { Transaction.count } do
      get list(q: "corner", period: "last_month")
    end
    assert_equal balance, @account.reload.balance
  end

  test "another user's account is still a 404 with filters" do
    other = User.create!(email_address: "other-search@example.com", password: "password123")
    plan = PlanLifecycle.create_plan(other, name: "Other")
    account = plan.accounts.create!(name: "Theirs", type: "checking")
    get users_budget_account_transactions_path(plan.public_id, account.public_id, q: "x")
    assert_response :not_found
  end
end
