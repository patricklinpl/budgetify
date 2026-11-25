require "application_system_test_case"

# On a wide screen the date presets and the payee search share one row, search
# at the right. On a phone they stay stacked inside the page. The search keeps
# its name and its filters. [engineering] Synthetic data.
class RegisterControlsRowTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Controls plan")
    @account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    writer = TransactionWriter.new(@plan)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -5_000, "payee_name" => "Alpha Cafe", "cleared" => "uncleared"))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def rects
    page.evaluate_script(<<~JS)
      (function () {
        var f = document.querySelector(".register-page__search").getBoundingClientRect();
        var n = document.querySelector(".register-page__periods").getBoundingClientRect();
        return { fTop: f.top, fBottom: f.bottom, fLeft: f.left, fRight: f.right, nTop: n.top, nBottom: n.bottom, nRight: n.right,
                 scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth };
      })()
    JS
  end

  test "at 1280px the presets are left and the search is right on one row" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    r = rects
    assert_operator r["fTop"], :<, r["nBottom"]
    assert_operator r["nTop"], :<, r["fBottom"]
    assert_operator r["nRight"], :<=, r["fLeft"]
    assert_operator r["scroll"], :<=, r["client"]
  end

  test "at 390px the search and presets stay stacked and inside the page" do
    page.driver.browser.manage.window.resize_to(390, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    r = rects
    assert_operator r["fBottom"], :<=, r["nTop"] + 0.5
    assert_operator r["fRight"], :<=, r["client"]
    assert_operator r["scroll"], :<=, r["client"]
  end

  test "the search keeps its accessible name and filters rows" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    fill_in "Search payee", with: "Alpha"
    click_button "Search"
    assert_field "Search payee", with: "Alpha"
    assert_no_selector "td[data-label='Payee']", text: "Zzz"
    assert_selector "td[data-label='Payee']", text: "Alpha Cafe"
  end
end
