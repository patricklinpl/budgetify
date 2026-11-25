require "application_system_test_case"

# Real browser run of Reflect > Spending Breakdown (#64 slice 2). Native clicks
# and keys. The plan is synthetic; the loan 300 is the [engineering] categorized
# transfer shape, not reference paired-category parity. Set PROOF_DIR to save
# screenshots of each state.
class ReflectSystemTest < ApplicationSystemTestCase
  setup do
    travel_to Date.new(2026, 11, 30)
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Reflect plan")
    writer = TransactionWriter.new(@plan)
    cash = Account.open!(budget: @plan, attributes: { "name" => "Cash", "type" => "cash", "balance" => 1_000_000 })
    loan = Account.open!(budget: @plan, attributes: { "name" => "Loan", "type" => "personalLoan", "balance" => -500_000 })
    needs = @plan.category_groups.create!(name: "Test Needs")
    audit = @plan.category_groups.create!(name: "TEST Audit")
    loan_cat = audit.categories.create!(budget: @plan, name: "Loan payment")
    @groceries = needs.categories.create!(budget: @plan, name: "Groceries")
    add = lambda do |amount, date, cat, transfer: nil|
      attrs = { "account_id" => cash.public_id, "date" => date, "amount" => amount, "category_id" => cat.public_id, "payee_name" => "Shop" }
      attrs["transfer_account_id"] = loan.public_id if transfer
      writer.persist_new!(writer.build(attrs))
    end
    add.call(-300_000, "2026-11-10", loan_cat, transfer: true)
    add.call(-10_000, "2026-11-11", @groceries)
    add.call(-10_000, "2026-11-12", @groceries)
    add.call(-13_210, "2026-11-13", @groceries)
    add.call(-20_000, "2026-10-05", @groceries)
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  teardown { travel_back }

  def shot(name)
    dir = ENV["PROOF_DIR"]
    return unless dir
    FileUtils.mkdir_p(dir)
    page.save_screenshot(File.join(dir, "#{name}.png"))
  end

  test "sidebar to Reflect, range, filter, groups, drilldown, reset and keyboard" do
    visit users_budget_path(@plan.public_id)
    within(".app-shell-nav") { click_link "Reflect" }
    assert_current_path users_budget_reflect_path(@plan.public_id)
    assert_selector "h2", text: "Spending Breakdown"
    assert_selector "#reflect-total", text: "$333.21"
    assert_selector "#reflect-daily", text: "$11.11"
    assert_selector "#reflect-chart"
    shot "01-default"

    click_link "Last 3 months"
    assert_selector "#reflect-total", text: "$353.21"
    assert_selector "#reflect-monthly", text: "$176.60"
    assert_selector "#reflect-daily", text: "$5.79"
    shot "02-last-3-months"

    visit users_budget_reflect_path(@plan.public_id)
    # Native month inputs take keystrokes as month then year.
    find_field("Start month").send_keys("10", "2026")
    find_field("End month").send_keys("11", "2026")
    click_button "Apply"
    assert_selector "#reflect-total", text: "$353.21"

    select "Test Needs: Groceries", from: "Categories"
    click_button "Apply"
    assert_selector "#reflect-total", text: "$53.21"
    assert_selector "ul[aria-label='Chart legend'] li", count: 1
    shot "03-groceries-filter"

    click_link "Reset"
    assert_selector "#reflect-total", text: "$333.21"
    choose "Groups"
    click_button "Apply"
    assert_selector "table[aria-label='Spending by group']"
    assert_selector "tbody tr", text: /TEST Audit.*90\.0%/
    shot "04-groups"

    click_link "Test Needs"
    assert_selector "h3", text: "Transactions: Test Needs"
    assert_selector "table[aria-label='Transactions for Test Needs'] tbody tr", count: 3
    shot "05-drilldown"

    find("a", text: "Reset").send_keys(:enter)
    assert_selector "#reflect-total", text: "$333.21"
    assert_no_selector "h3"
  end

  test "empty range and phone width" do
    visit users_budget_reflect_path(@plan.public_id, start: "2026-01", end: "2026-01")
    assert_selector "[role=status]", text: "No spending in this range."
    assert_no_selector "#reflect-chart"
    shot "06-empty"
    page.driver.browser.manage.window.resize_to(390, 900)
    visit users_budget_reflect_path(@plan.public_id)
    assert_selector "#reflect-chart"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"), "page scrolls sideways at phone width"
    shot "07-phone"
    page.execute_script("document.querySelector('#reflect-chart').scrollIntoView()")
    shot "08-phone-chart"
    page.execute_script("document.querySelector('table[aria-label=\"Spending by category\"]').scrollIntoView()")
    shot "09-phone-table"
    visit users_budget_reflect_path(@plan.public_id, drill: @groceries.public_id)
    assert_selector "h3", text: "Transactions: Groceries"
    page.execute_script("document.querySelector('h3').scrollIntoView()")
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"), "drilldown scrolls sideways at phone width"
    shot "10-phone-drilldown"
  end

  test "[engineering] refund category: charted spending and net total are labelled separately" do
    cash = @plan.accounts.find_by!(name: "Cash")
    returns = @plan.category_groups.create!(name: "Refund group").categories.create!(budget: @plan, name: "Returns")
    writer = TransactionWriter.new(@plan)
    add = lambda do |amount, date|
      writer.persist_new!(writer.build("account_id" => cash.public_id, "date" => date, "amount" => amount, "category_id" => returns.public_id, "payee_name" => "Shop"))
    end
    add.call(20_000, "2026-11-14")
    visit users_budget_reflect_path(@plan.public_id)
    assert_selector "#reflect-total", text: "$313.21"
    assert_selector ".reflect-donut__hole", text: "Spending excluding refunds"
    assert_selector "#reflect-refund-note"
    shot "11-mixed-refund"
    page.execute_script("document.querySelector('#reflect-refund-note').scrollIntoView()")
    add.call(400_000, "2026-11-15")
    visit users_budget_reflect_path(@plan.public_id)
    assert_selector ".reflect-donut__hole", text: "Spending excluding refunds"
    assert_selector "#reflect-refund-note"
    shot "12-net-negative-total"
    page.driver.browser.manage.window.resize_to(390, 900)
    visit users_budget_reflect_path(@plan.public_id)
    page.execute_script("document.querySelector('#reflect-chart').scrollIntoView()")
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"), "refund case scrolls sideways at phone width"
    shot "13-phone-net-negative"
  end
end
