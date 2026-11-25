require "application_system_test_case"

# [engineering] Flat plan toolbar actions: no outline or fill when enabled,
# a dashed outline when disabled, text contrast against the real backdrop,
# and the same controls and enabled state as before. Real Chrome, real layout.
class PlanToolbarFlatTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Flat toolbar plan")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  ROWS_JS = <<~JS.freeze
    (function () {
      function nums(s) { return s.match(/[\\d.]+/g).map(Number); }
      function lum(c) { var a = c.slice(0, 3).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]; }
      function backdrop(e) {
        for (var n = e; n; n = n.parentElement) {
          var b = nums(getComputedStyle(n).backgroundColor);
          if (b.length < 4 || b[3] === 1) return b;
        }
        return [255, 255, 255, 1];
      }
      return [...document.querySelectorAll('.shell-header--plan .shell-toolbar .shell-button')].map(function (e) {
        var s = getComputedStyle(e), l1 = lum(nums(s.color)), l2 = lum(backdrop(e));
        var hi = Math.max(l1, l2), lo = Math.min(l1, l2);
        return { t: e.textContent.trim(), dis: e.disabled, bstyle: s.borderTopStyle, bcolor: s.borderTopColor, bg: s.backgroundColor, op: s.opacity, ratio: Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100 };
      });
    })()
  JS

  test "enabled toolbar actions are flat and disabled ones keep a dashed outline" do
    visit users_budget_path(@plan.public_id)
    rows = page.evaluate_script(ROWS_JS)
    assert_equal [ "Add Category Group", "Undo", "Redo", "Recent Moves" ], rows.map { |r| r["t"] }
    rows.each do |r|
      if r["dis"]
        assert_equal "dashed", r["bstyle"], r.inspect
      else
        assert_equal "rgba(0, 0, 0, 0)", r["bcolor"], r.inspect
        assert_equal "rgba(0, 0, 0, 0)", r["bg"], r.inspect
      end
    end
    assert_equal [ "Add Category Group", "Undo", "Redo" ], rows.select { |r| r["dis"] }.map { |r| r["t"] }
    assert_equal [ "Recent Moves" ], rows.reject { |r| r["dis"] }.map { |r| r["t"] }
  end

  %w[light dark].each do |theme|
    test "enabled toolbar action text keeps at least 4.5:1 contrast in the #{theme} theme" do
      visit users_budget_path(@plan.public_id)
      page.execute_script("document.documentElement.setAttribute('data-theme','#{theme}')")
      rows = page.evaluate_script(ROWS_JS).reject { |r| r["dis"] }
      assert_equal 1, rows.size
      puts "TOOLBAR_CONTRAST #{theme} #{rows.map { |r| "#{r['t']}=#{r['ratio']}" }.join(' ')}"
      rows.each { |r| assert_operator r["ratio"], :>=, 4.5, "#{r['t']} contrast #{r['ratio']}:1 in #{theme}" }
    end
  end
end
