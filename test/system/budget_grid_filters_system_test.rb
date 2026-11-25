require "application_system_test_case"

# #59 grid filter chips in a real browser, normal clicks only: click a chip, assert
# the URL and the listed rows, click All to restore. [engineering] The chips are
# links to GET ?filter=; this app's own choice, only the Overspent and Money
# Available vectors came from the reference. Synthetic data.
class BudgetGridFiltersSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Chip plan")
    @plan.categories.where(internal: false).update_all(deleted: true)
    @plan.category_groups.where(internal: false).update_all(deleted: true)
    account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    group = @plan.category_groups.create!(name: "Needs")
    @groceries = group.categories.create!(budget: @plan, name: "Groceries")
    dining = group.categories.create!(budget: @plan, name: "Dining")
    loan = group.categories.create!(budget: @plan, name: "Loan")
    MonthAssignment.set!(budget: @plan, category: dining, month: Date.current.beginning_of_month, amount: 10_000, user: @user)
    writer = TransactionWriter.new(@plan)
    writer.persist_new!(writer.build("account_id" => account.public_id, "date" => Date.current.iso8601, "amount" => -30_000,
      "payee_name" => "Lender", "category_id" => loan.public_id, "cleared" => "uncleared"))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_path(@plan.public_id)
  end

  def rows = all("tr.data-table__row .budget-grid__name").map { |cell| cell.text.sub(/\s*Edit\s*Target\s*\z/, "").strip }

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  # Retries until the listed rows match, so a Turbo page swap cannot leave a stale node.
  def assert_rows(expected)
    page.document.synchronize { raise Capybara::ExpectationNotMet, "rows #{rows.inspect}" unless rows.sort == expected.sort }
  end

  test "clicking the chips filters the grid and All restores it" do
    assert_rows %w[Dining Groceries Loan]
    click_link "Money Available"
    assert_current_path(/filter=money_available/)
    assert_rows %w[Dining]
    assert_text "2 categories hidden by the Money Available filter"
    click_link "Overspent"
    assert_current_path(/filter=overspent/)
    assert_rows %w[Loan]
    click_link "All"
    assert_no_current_path(/filter=/)
    assert_rows %w[Dining Groceries Loan]
  end

  test "the filter survives toggling hidden categories" do
    @groceries.update!(hidden: true)
    visit users_budget_path(@plan.public_id, filter: "overspent")
    click_link "Show 1 hidden category"
    assert_current_path(/hidden=1/)
    assert_current_path(/filter=overspent/)
    assert_rows %w[Loan]
    click_link "Money Available"
    assert_current_path(/hidden=1/)
    assert_current_path(/filter=money_available/)
  end

  test "the plan page with a filter active does not scroll sideways at 390px" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_path(@plan.public_id, filter: "money_available")
    assert_text "2 categories hidden by the Money Available filter"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth")
  end
end
