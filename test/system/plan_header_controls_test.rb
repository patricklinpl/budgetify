require "application_system_test_case"

# [engineering] Plan header controls: touch size on a phone, the Recent Moves
# box, disabled-state semantics, chip contrast and keyboard focus. Real Chrome,
# real layout, no stubs. Sizes are the bounding boxes the page reports.
class PlanHeaderControlsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Header controls plan")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def sizes(selector)
    page.evaluate_script("[...document.querySelectorAll(#{selector.to_json})].map(function(e){var r=e.getBoundingClientRect();return {t:e.textContent.trim().slice(0,20),w:Math.round(r.width),h:Math.round(r.height),dis:!!e.disabled}})")
  end

  test "at phone width every plan header control is at least 44px high and Recent Moves is one 44px box" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_path(@plan.public_id)
    assert_selector ".shell-header--plan .shell-chip", count: 6
    controls = sizes(".shell-header--plan .shell-chip, .shell-header--plan .shell-toolbar .shell-button, .shell-header--plan .shell-icon-button")
    assert_equal 6 + 4 + 2, controls.size
    controls.each do |c|
      assert_operator c["h"], :>=, 44, "#{c['t']} is #{c['w']}x#{c['h']}"
      assert_operator c["w"], :>=, 44, "#{c['t']} is #{c['w']}x#{c['h']}"
    end
    moves = sizes(".shell-toolbar a.shell-button").find { |c| c["t"] == "Recent Moves" }
    assert_equal 44, moves["h"], "Recent Moves box is #{moves['w']}x#{moves['h']}"
  end

  test "disabled controls stay disabled and the All, Overspent and Money Available chips stay real links" do
    visit users_budget_path(@plan.public_id)
    disabled = page.evaluate_script("[...document.querySelectorAll('.shell-header--plan .shell-chip')].filter(function(e){return e.disabled}).map(function(e){return e.textContent.trim()})")
    assert_equal %w[Underfunded Overfunded Snoozed], disabled
    links = page.evaluate_script("[...document.querySelectorAll('.shell-header--plan a.shell-chip')].map(function(e){return e.textContent.trim()})")
    assert_equal [ "All", "Overspent", "Money Available" ], links
    assert_equal "true", page.evaluate_script("document.querySelector('a.shell-chip--active').getAttribute('aria-current')")
    assert_selector ".shell-header--plan .shell-chip--active", text: "All"
    assert_selector ".shell-header--plan .shell-button[disabled]", text: "Add Category Group"
  end

  %w[light dark].each do |theme|
    test "enabled and active chip text keeps at least 4.5:1 contrast in the #{theme} theme" do
      visit users_budget_path(@plan.public_id)
      page.execute_script("document.documentElement.setAttribute('data-theme','#{theme}')")
      js = <<~JS
        (function () {
          function rgb(s) { var m = s.match(/[\\d.]+/g).map(Number); return m; }
          function lum(c) { var a = c.slice(0, 3).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]; }
          return [...document.querySelectorAll('.shell-header--plan .shell-chip')].filter(function (e) { return !e.disabled }).map(function (e) {
            var s = getComputedStyle(e), f = rgb(s.color), b = rgb(s.backgroundColor);
            var l1 = lum(f), l2 = lum(b), hi = Math.max(l1, l2), lo = Math.min(l1, l2);
            return { t: e.textContent.trim(), ratio: Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100, alpha: b[3] === undefined ? 1 : b[3] };
          });
        })()
      JS
      rows = page.evaluate_script(js)
      assert_equal 3, rows.size
      rows.each do |r|
        assert_equal 1, r["alpha"], "#{r['t']} background is not opaque, ratio would be unreliable"
        assert_operator r["ratio"], :>=, 4.5, "#{r['t']} contrast #{r['ratio']}:1 in #{theme}"
      end
    end
  end

  test "a chip link takes keyboard focus and shows a focus outline" do
    visit users_budget_path(@plan.public_id)
    page.execute_script("document.querySelector('a.shell-chip').focus()")
    page.driver.browser.action.send_keys(:shift, :tab, :tab).perform
    outline = page.evaluate_script("(function(){var e=document.activeElement;var s=getComputedStyle(e);return {tag:e.tagName,cls:e.className,style:s.outlineStyle,w:s.outlineWidth}})()")
    assert_equal "A", outline["tag"], outline.inspect
    assert_includes outline["cls"], "shell-chip"
    assert_not_equal "none", outline["style"], outline.inspect
    assert_operator outline["w"].to_f, :>, 0, outline.inspect
  end
end
