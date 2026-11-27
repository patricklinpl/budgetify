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
end
