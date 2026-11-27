require "application_system_test_case"

# The balance line on the register stays visible and inside the page at phone
# and desktop widths, with long amounts. [engineering] Synthetic data.
class RegisterBalanceLineSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Balance plan")
    @account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 123_456_789_000 })
    writer = TransactionWriter.new(@plan)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -12_345_670, "payee_name" => "Shop", "cleared" => "uncleared"))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  [ [ 390, "phone" ], [ 1280, "desktop" ] ].each do |width, name|
    test "the balance line fits at #{name} width" do
      page.driver.browser.manage.window.resize_to(width, 900)
      visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
      assert_selector ".register-page .shell-balance-summary", text: "Cleared"
      box = page.evaluate_script(<<~JS)
        (function () {
          var e = document.querySelector(".register-page .shell-balance-summary").getBoundingClientRect();
          return { left: e.left, right: e.right, width: e.width, scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth };
        })()
      JS
      assert_operator box["left"], :>=, 0
      assert_operator box["right"], :<=, box["client"]
      assert_operator box["scroll"], :<=, box["client"]
      assert_text "Working"
    end
  end

  test "on a phone the three amounts stack and the signs sit in front of the second and third" do
    page.driver.browser.manage.window.resize_to(390, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    assert_selector ".register-page .shell-balance-summary", text: "Cleared"
    info = page.evaluate_script(<<~JS)
      (function () {
        var root = document.querySelector(".register-page .shell-balance-summary");
        var parts = Array.prototype.slice.call(root.querySelectorAll(":scope > .shell-balance"));
        return {
          tops: parts.map(function (e) { return Math.round(e.getBoundingClientRect().top); }),
          lefts: parts.map(function (e) { return Math.round(e.getBoundingClientRect().left); }),
          signs: parts.map(function (e) { return getComputedStyle(e, "::before").content; }),
          hidden: Array.prototype.slice.call(root.querySelectorAll(":scope > [aria-hidden='true']")).map(function (e) { return getComputedStyle(e).display; })
        };
      })()
    JS
    assert_equal 3, info["tops"].length
    assert_operator info["tops"][0], :<, info["tops"][1]
    assert_operator info["tops"][1], :<, info["tops"][2]
    assert_equal 1, info["lefts"].uniq.length
    assert_equal [ "none", "none" ], info["hidden"]
    assert_includes info["signs"][1], "+"
    assert_includes info["signs"][2], "="
  end

  test "on a wide screen the line stays on one row with the signs between the amounts" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    assert_selector ".register-page .shell-balance-summary", text: "Cleared"
    tops = page.evaluate_script('Array.prototype.map.call(document.querySelectorAll(".register-page .shell-balance-summary > .shell-balance"), function (e) { return Math.round(e.getBoundingClientRect().top); })')
    assert_equal 1, tops.uniq.length
    assert_text "+"
  end
end
