require "application_system_test_case"

# [engineering] DIAGNOSTIC ONLY: records which test ran just before in this process.
module DiagPrevTest
  def after_teardown
    super
    $diag_prev = name
  end
end
ApplicationSystemTestCase.prepend(DiagPrevTest)

# On phones the shell sidebar is always the rail: a desktop "expanded"
# choice stored in the browser must not cover or squeeze the page.
class AppShellPhoneTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = @user.budgets.create!(name: "Household")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  test "accounts stay reachable at 390px by click and keyboard and select the account route" do
    checking = @plan.accounts.create!(name: "Everyday", type: "checking")
    @plan.accounts.create!(name: "Rainy", type: "savings")
    # [engineering] DIAGNOSTIC ONLY: pass-path recording, assertions unchanged.
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ms = -> { ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round }
    diag = { prev: $diag_prev.inspect }
    tl_mark = ChromedriverTimeline.enabled? ? ChromedriverTimeline.mark : nil
    win = page.driver.browser.manage.window
    diag[:size_before_resize] = "#{win.size.width}x#{win.size.height}"
    win.resize_to(390, 844)
    diag[:resize_done_ms] = ms.call
    diag[:size_after_resize] = "#{win.size.width}x#{win.size.height}"
    visit users_budget_path(@plan.public_id)
    diag[:visit_done_ms] = ms.call
    assert_selector ".app-shell-phone-accounts summary", text: "Accounts"
    diag[:summary_seen_ms] = ms.call
    install_input_log
    diag[:pre_send] = page.evaluate_script("JSON.stringify({focus: document.hasFocus(), vis: document.visibilityState, active: document.activeElement.tagName, age: Math.round(performance.now()), inner: innerWidth + 'x' + innerHeight})")
    diag[:before_send_ms] = ms.call
    begin
      with_input_diagnostics do
        find(".app-shell-phone-accounts summary").send_keys(:enter)
        diag[:after_send_ms] = ms.call
        assert_selector ".app-shell-phone-accounts__link", count: 2
      end
    ensure
      diag[:end_ms] = ms.call
      diag[:post] = begin
        page.evaluate_script("JSON.stringify({open: document.querySelector('.app-shell-phone-accounts details').open, keydown: (window.__inputLog || []).filter(function (l) { return /keydown Enter/.test(l); }).length, keyup: (window.__inputLog || []).filter(function (l) { return /keyup Enter/.test(l); }).length, focus: document.hasFocus(), age: Math.round(performance.now())})")
      rescue StandardError => e
        "eval failed #{e.class}"
      end
      diag[:input_log] = begin
        page.evaluate_script("JSON.stringify(window.__inputLog || [])")
      rescue StandardError => e
        "eval failed #{e.class}"
      end
      puts "DIAGORIG #{diag.inspect}"
      begin
        if tl_mark
          result = ChromedriverTimeline.skeleton(ChromedriverTimeline.current_path, from: tl_mark)
          warn ChromedriverTimeline.report("AppShellPhoneTest accounts (printed on pass and fail)", result)
        end
      rescue StandardError => e
        warn "CHROMEDRIVER_TIMELINE unavailable: #{e.class}"
      end
    end
    link = find(".app-shell-phone-accounts__link", text: "Everyday")
    install_input_log
    assert_operator link.native.rect.width, :>=, 44
    assert_operator link.native.rect.height, :>=, 44
    diag_click(link, "account link Everyday")
    with_input_diagnostics("Everyday") { assert_current_path users_budget_path(@plan.public_id, account: checking.public_id) }
    assert_selector ".app-shell-phone-accounts summary", text: "Everyday"
    find(".app-shell-phone-accounts summary").send_keys(:enter)
    assert_selector ".app-shell-phone-accounts__link[aria-current=page]", text: "Everyday"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth")
  end

  test "phone account list is hidden on desktop" do
    @plan.accounts.create!(name: "Everyday", type: "checking")
    visit users_budget_path(@plan.public_id)
    assert_no_selector ".app-shell-phone-accounts", visible: :visible
  end

  test "stored expanded state is ignored at 390px on every shell route and restored on desktop" do
    visit users_budget_path(@plan.public_id)
    page.execute_script("localStorage.setItem('budgetify.sidebarCollapsed', 'false')")
    page.driver.browser.manage.window.resize_to(390, 844)

    [ users_budget_path(@plan.public_id), settings_users_budget_path(@plan.public_id) ].each do |path|
      visit path
      assert_selector ".app-shell.app-shell--collapsed"
      assert_no_selector ".app-shell-collapse", visible: :visible
      assert_equal 56, page.evaluate_script("document.querySelector('.app-shell-sidebar').getBoundingClientRect().width").round
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth"), path
      assert page.evaluate_script("document.querySelector('.app-shell-main').getBoundingClientRect().left >= 56"), path
      assert_selector ".app-shell-nav-item", count: 4
    end
    assert_equal "false", page.evaluate_script("localStorage.getItem('budgetify.sidebarCollapsed')")

    page.driver.browser.manage.window.resize_to(1400, 1000)
    assert_no_selector ".app-shell--collapsed"
    assert_selector ".app-shell-collapse"
  end
end
