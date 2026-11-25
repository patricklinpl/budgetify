require "application_system_test_case"

# Phone width: the Available pill, including the exact value for a sub-display
# precision amount, and the Cover link stay inside their row, with the exact text
# still shown (wrapped, not clipped). [engineering] Synthetic data, real Chrome.
class BudgetGridPillContainmentTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Pill containment plan")
    @plan.categories.where(internal: false).update_all(deleted: true)
    @plan.category_groups.where(internal: false).update_all(deleted: true)
    Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 3_000_000 })
    group = @plan.category_groups.create!(name: "Bills")
    month = Date.current.beginning_of_month
    { "Big positive" => 987_654_321, "Big negative" => -987_654_321, "Plain" => 20_000 }.each do |name, amount|
      category = group.categories.create!(budget: @plan, name: name)
      MonthAssignment.set!(budget: @plan, category: category, month: month, amount: amount, user: @user)
    end
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  test "available pill and Cover stay inside the row at 390px with the exact value shown" do
    page.driver.browser.manage.window.resize_to(390, 1000)
    visit users_budget_path(@plan.public_id)
    rows = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("tr.data-table__row")).map(function (tr) {
        var row = tr.getBoundingClientRect();
        var items = Array.from(tr.querySelectorAll("td[data-label='Available'] .status-pill, td[data-label='Available'] a")).map(function (el) {
          var r = el.getBoundingClientRect();
          return { text: el.innerText, right: r.right, left: r.left };
        });
        return { name: tr.innerText.split("\\n")[0], right: row.right, left: row.left, items: items };
      });
    JS
    assert_equal 3, rows.size
    rows.each do |row|
      row["items"].each do |item|
        assert_operator item["right"], :<=, row["right"] + 0.5, "#{row['name']}: #{item['text'].inspect} overflows the row on the right"
        assert_operator item["left"], :>=, row["left"] - 0.5, "#{row['name']}: #{item['text'].inspect} overflows the row on the left"
      end
    end
    texts = rows.flat_map { |row| row["items"].map { |item| item["text"] } }.join(" ")
    assert_includes texts, "exact 987654.321"
    assert_includes texts, "exact -987654.321"
    assert_includes texts, "Cover"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth")
  end

  %w[light dark].each do |theme|
    test "the exact annotation inside an Available pill keeps at least 4.5:1 contrast in the #{theme} theme" do
      visit users_budget_path(@plan.public_id)
      page.execute_script("document.documentElement.setAttribute('data-theme','#{theme}')")
      rows = page.evaluate_script(<<~JS)
        (function () {
          function rgb(s) { return s.match(/[\\d.]+/g).map(Number); }
          function lum(c) { var a = c.slice(0, 3).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]; }
          return Array.from(document.querySelectorAll(".status-pill .budget-grid__exact")).map(function (e) {
            var pill = e.closest(".status-pill"), b = rgb(getComputedStyle(pill).backgroundColor), f = rgb(getComputedStyle(e).color);
            var l1 = lum(f), l2 = lum(b), hi = Math.max(l1, l2), lo = Math.min(l1, l2);
            return { t: e.textContent.trim(), ratio: Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100, alpha: b[3] === undefined ? 1 : b[3] };
          });
        })()
      JS
      assert_equal 2, rows.size
      rows.each do |r|
        assert_equal 1, r["alpha"], "#{r['t']} pill background is not opaque"
        assert_operator r["ratio"], :>=, 4.5, "#{r['t']} contrast #{r['ratio']}:1 in #{theme}"
      end
    end
  end
end
