require "application_system_test_case"

# A transaction with no category shows "Needs a category" as an amber chip.
# The text is the existing text; this checks colour contrast in both themes and
# that the chip stays inside its row at phone width. [engineering] Synthetic data.
class RegisterNeedsCategoryChipTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Chip plan")
    @account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    writer = TransactionWriter.new(@plan)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -12_000,
      "payee_name" => "Mystery Shop", "cleared" => "uncleared"))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  %w[light dark].each do |theme|
    test "the chip text keeps at least 4.5:1 contrast in the #{theme} theme" do
      visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
      page.execute_script("document.documentElement.setAttribute('data-theme','#{theme}')")
      rows = page.evaluate_script(<<~JS)
        (function () {
          function rgb(s) { return s.match(/[\\d.]+/g).map(Number); }
          function lum(c) { var a = c.slice(0, 3).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]; }
          return Array.from(document.querySelectorAll("td[data-label='Category'] .register-chip")).map(function (e) {
            var s = getComputedStyle(e), f = rgb(s.color), b = rgb(s.backgroundColor);
            var l1 = lum(f), l2 = lum(b), hi = Math.max(l1, l2), lo = Math.min(l1, l2);
            return { t: e.textContent.trim(), ratio: Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100, alpha: b[3] === undefined ? 1 : b[3] };
          });
        })()
      JS
      assert_equal 1, rows.size
      assert_equal "Needs a category", rows.first["t"]
      assert_equal 1, rows.first["alpha"]
      assert_operator rows.first["ratio"], :>=, 4.5, "contrast #{rows.first['ratio']}:1 in #{theme}"
    end
  end

  test "the chip stays inside its row at 390px and the category text is unchanged" do
    page.driver.browser.manage.window.resize_to(390, 900)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    box = page.evaluate_script(<<~JS)
      (function () {
        var chip = document.querySelector(".register-chip"), row = chip.closest("tr").getBoundingClientRect(), c = chip.getBoundingClientRect();
        return { left: c.left, right: c.right, rowLeft: row.left, rowRight: row.right, scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth };
      })()
    JS
    assert_operator box["right"], :<=, box["rowRight"] + 0.5
    assert_operator box["left"], :>=, box["rowLeft"] - 0.5
    assert_operator box["scroll"], :<=, box["client"]
    assert_selector "td[data-label='Category']", text: "Needs a category", exact_text: true
  end
end
