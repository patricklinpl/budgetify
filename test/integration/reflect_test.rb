require "test_helper"

# #64 slice 2: Reflect > Spending Breakdown. [reference T] numbers are the
# audit's (REPORT-06/07/09, REPORT-CUSTOM-01) reproduced on a synthetic plan.
# The loan 300 is built as a categorized transfer to a loan account, which is
# an [engineering] shape and NOT reference paired-category parity (#66).
# Last 3 months anchor and share ordering are [engineering] rules.
class ReflectTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Date.new(2026, 11, 30)
    @user = users(:one)
    sign_in_as(@user)
    @plan = PlanLifecycle.create_plan(@user, name: "Reflect plan")
    @writer = TransactionWriter.new(@plan)
    @cash = Account.open!(budget: @plan, attributes: { "name" => "Cash", "type" => "cash", "balance" => 1_000_000 })
    @loan = Account.open!(budget: @plan, attributes: { "name" => "Loan", "type" => "personalLoan", "balance" => -500_000 })
    audit = @plan.category_groups.create!(name: "TEST Audit")
    needs = @plan.category_groups.create!(name: "Test Needs")
    @loan_cat = audit.categories.create!(budget: @plan, name: "Loan payment")
    @groceries = needs.categories.create!(budget: @plan, name: "Groceries")
    put(@cash, -300_000, "2026-11-10", @loan_cat, loan: true)
    put(@cash, -10_000, "2026-11-11", @groceries)
    put(@cash, -10_000, "2026-11-12", @groceries)
    put(@cash, -13_210, "2026-11-13", @groceries)
    @october = put(@cash, -20_000, "2026-10-05", @groceries)
  end

  teardown { travel_back }

  def put(account, amount, date, category, loan: false)
    attrs = { "account_id" => account.public_id, "date" => date, "amount" => amount, "category_id" => category.public_id, "payee_name" => "Shop" }
    attrs["transfer_account_id"] = @loan.public_id if loan
    @writer.persist_new!(@writer.build(attrs))
  end

  def page(params = {}) = get(users_budget_reflect_path(@plan.public_id, params))
  def text(selector) = css_select(selector).first&.text.to_s.strip

  test "[engineering] the sidebar links Reflect and marks it current on the page" do
    page
    assert_response :success
    assert_select "nav[aria-label='Plan navigation'] a[href='#{users_budget_reflect_path(@plan.public_id)}'][aria-current='page']", text: "Reflect"
    assert_select "nav[aria-label='Plan navigation'] a[aria-current='page']", count: 1
    assert_select "span.app-shell-nav-item--inactive", text: "All Accounts"
  end

  test "[reference T] this month: 333.21 total, monthly 333.21, daily 11.11, loan 300 (90%) and Groceries 33.21 (10%)" do
    page
    assert_equal "$333.21", text("#reflect-total")
    assert_equal "$333.21", text("#reflect-monthly")
    assert_equal "$11.11", text("#reflect-daily")
    assert_select "table[aria-label='Spending by category'] tbody tr", count: 2
    assert_select "table[aria-label='Spending by category'] tbody tr:first-child", text: /Loan payment.*\$300\.00.*90\.0%.*1/m
    assert_select "table[aria-label='Spending by category'] tbody tr:last-child", text: /Groceries.*\$33\.21.*10\.0%.*3/m
  end

  test "[reference T] custom Oct-Nov: 353.21 total, monthly 176.60, daily 5.79" do
    page(start: "2026-10", end: "2026-11")
    assert_equal "$353.21", text("#reflect-total")
    assert_equal "$176.60", text("#reflect-monthly")
    assert_equal "$5.79", text("#reflect-daily")
  end

  test "[reference T] deleting the October row keeps the Oct-Nov selection: 333.21, 166.60, 5.46, empty month stays in the divisor" do
    @writer.destroy!(@october)
    page(start: "2026-10", end: "2026-11")
    assert_equal "$333.21", text("#reflect-total")
    assert_equal "$166.60", text("#reflect-monthly")
    assert_equal "$5.46", text("#reflect-daily")
  end

  test "[engineering] Last 3 months starts at the earliest on-budget activity month, not three artificial months" do
    page
    assert_select "a", text: "Last 3 months" do |links|
      assert_includes links.first["href"], "start=2026-10"
      assert_includes links.first["href"], "end=2026-11"
    end
    @writer.destroy!(@october)
    page
    assert_select "a", text: "Last 3 months" do |links|
      assert_includes links.first["href"], "start=2026-11"
    end
  end

  test "[engineering] an opening-balance row does not anchor Last 3 months" do
    assert @plan.transactions.where(opening_balance: true).update_all(date: Date.new(2026, 9, 1)).positive?
    page
    assert_select "a", text: "Last 3 months" do |links|
      assert_includes links.first["href"], "start=2026-10"
    end
  end

  test "[engineering] Last 3 months never reaches back more than two months" do
    @plan.transactions.not_deleted.where(opening_balance: false).update_all(date: Date.new(2026, 5, 1))
    page
    assert_select "a", text: "Last 3 months" do |links|
      assert_includes links.first["href"], "start=2026-09"
    end
  end

  test "[reference T] groups: total preserved, TEST Audit 300 (90%), Needs 33.21 (10%)" do
    page(by: "groups")
    assert_equal "$333.21", text("#reflect-total")
    assert_select "table[aria-label='Spending by group'] tbody tr", count: 2
    assert_select "table[aria-label='Spending by group'] tbody tr:first-child", text: /TEST Audit.*\$300\.00.*90\.0%/m
    assert_select "table[aria-label='Spending by group'] tbody tr:last-child", text: /Test Needs.*\$33\.21.*10\.0%/m
  end

  test "[reference T shape] category filter changes summary and chart together, reset restores" do
    page(categories: [ @groceries.public_id ])
    assert_equal "$33.21", text("#reflect-total")
    assert_equal "$33.21", text("#reflect-chart .reflect-donut__hole strong")
    assert_select "ul[aria-label='Chart legend'] li", count: 1
    page
    assert_equal "$333.21", text("#reflect-total")
    assert_select "ul[aria-label='Chart legend'] li", count: 2
  end

  test "[engineering] chart gradient, legend and table come from the same slices" do
    page
    style = css_select("#reflect-chart").first["style"]
    assert_match(/conic-gradient\(.*0\.0% 90\.0333%.*90\.0333% 100\.0%/, style)
    assert_equal "$333.21", text("#reflect-chart .reflect-donut__hole strong")
    assert_equal 2, css_select("ul[aria-label='Chart legend'] li").size
    assert_includes css_select("#reflect-chart").first["aria-label"], "Groceries $33.21"
  end

  test "[reference T shape] account filter limits the rows and the total" do
    other = Account.open!(budget: @plan, attributes: { "name" => "Other", "type" => "checking", "balance" => 100_000 })
    put(other, -4_560, "2026-11-14", @groceries)
    page(accounts: [ other.public_id ])
    assert_equal "$4.56", text("#reflect-total")
    page
    assert_equal "$337.77", text("#reflect-total")
  end

  test "[reference T] drilldown lists the exact transactions for a category and agrees with the breakdown count" do
    page(drill: @groceries.public_id)
    assert_select "table[aria-label='Transactions for Groceries'] tbody tr", count: 3
    assert_select "table[aria-label='Transactions for Groceries'] tbody tr:first-child", text: /2026-11-11.*Cash.*Shop.*\$10\.00/m
    assert_select "table[aria-label='Transactions for Groceries'] tbody tr:last-child", text: /\$13\.21/
  end

  test "[engineering] bad or inverted month params fall back to this month and never error" do
    [ { start: "nope" }, { start: "2026-13" }, { start: "2026-11", end: "2026-10" }, { end: "x" } ].each do |params|
      page(params)
      assert_response :success
      assert_equal "$333.21", text("#reflect-total")
    end
  end

  test "[engineering] ids from another plan are ignored, and another user's plan is a 404" do
    other_user = users(:two)
    foreign = PlanLifecycle.create_plan(other_user, name: "Foreign")
    foreign_cat = foreign.category_groups.create!(name: "G").categories.create!(budget: foreign, name: "Secret")
    page(categories: [ foreign_cat.public_id ], accounts: [ "nope" ], drill: foreign_cat.public_id)
    assert_response :success
    assert_equal "$333.21", text("#reflect-total")
    assert_select "table[aria-label^='Transactions for']", count: 0
    assert_not_includes response.body, "Secret"
    get users_budget_reflect_path(foreign.public_id)
    assert_response :not_found
  end

  test "[engineering] a net-refund category stays out of the chart and shares: no gradient stop past 100 percent" do
    refunds = @plan.category_groups.create!(name: "Refund group").categories.create!(budget: @plan, name: "Returns")
    put(@cash, 20_000, "2026-11-14", refunds)
    page
    assert_equal "$313.21", text("#reflect-total")
    style = css_select("#reflect-chart").first["style"]
    stops = style.scan(/(\d+(?:\.\d+)?)%/).flatten.map(&:to_f)
    assert stops.all? { |n| n.between?(0, 100) }, style
    assert_equal 100.0, stops.last
    assert_equal 2, css_select("ul[aria-label='Chart legend'] li").size
    assert_select "table[aria-label='Spending by category'] tbody tr:last-child", text: /Returns.*\$-?20\.00.*Refund/m
    assert_select "table[aria-label='Spending by category'] tbody tr", count: 3
    assert_select "p", text: /Net refunds are listed in the table/
    assert_select "table[aria-label='Spending by category'] tbody tr:first-child", text: /Loan payment.*\$300\.00.*90\.0%/m
  end

  test "[engineering] only net refunds in range: no chart, a note, no error" do
    refunds = @plan.category_groups.create!(name: "Refund group").categories.create!(budget: @plan, name: "Returns")
    put(@cash, 20_000, "2026-11-14", refunds)
    page(categories: [ refunds.public_id ])
    assert_response :success
    assert_select "#reflect-chart", count: 0
    assert_select "p[role=status]", text: /No category has net spending/
    assert_select "table tbody tr", text: /Returns.*Refund/m
  end

  test "[engineering] an empty range shows a message and zeros, no chart" do
    page(start: "2026-01", end: "2026-01")
    assert_select "[role=status]", text: "No spending in this range."
    assert_equal "$0.00", text("#reflect-total")
    assert_equal "$0.00", text("#reflect-daily")
    assert_select "#reflect-chart", count: 0
  end

  test "[engineering] the form has labelled controls and a reset link" do
    page
    assert_select "label[for=reflect_start]"
    assert_select "input#reflect_start[type=month][value='2026-11']"
    assert_select "select#reflect_categories[multiple]"
    assert_select "fieldset legend", text: "Accounts"
    assert_select "a[href='#{users_budget_reflect_path(@plan.public_id)}']", text: "Reset"
  end
end
