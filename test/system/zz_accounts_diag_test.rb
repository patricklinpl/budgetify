require "application_system_test_case"

# [engineering] DIAGNOSTIC ONLY, not for merge. Repeats the accounts-at-390px
# keyboard step many times in one run and records, per attempt, whether a
# keydown reached the page, whether the details opened, and the window and
# focus state. It asserts nothing about the outcome so every attempt is kept.
class ZzAccountsDiagTest < ApplicationSystemTestCase
  ATTEMPTS = 40

  setup do
    @user = users(:one)
    @plan = @user.budgets.create!(name: "Household")
    @plan.accounts.create!(name: "Everyday", type: "checking")
    @plan.accounts.create!(name: "Rainy", type: "savings")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  STATE_JS = <<~JS
    (function () {
      var d = document.querySelector(".app-shell-phone-accounts details");
      var log = window.__inputLog || [];
      return JSON.stringify({
        open: d ? d.open : null,
        keydown: log.filter(function (l) { return /keydown Enter/.test(l); }).length,
        keyup: log.filter(function (l) { return /keyup Enter/.test(l); }).length,
        toggles: log.filter(function (l) { return /toggle/.test(l); }).length,
        focus: document.hasFocus(), active: document.activeElement ? document.activeElement.tagName : "none",
        inner: [innerWidth, innerHeight], outer: [outerWidth, outerHeight], ready: document.readyState
      });
    })()
  JS

  test "repeat the accounts keyboard step and record every attempt" do
    results = []
    ATTEMPTS.times do |i|
      page.driver.browser.manage.window.resize_to(390, 844)
      visit users_budget_path(@plan.public_id)
      assert_selector ".app-shell-phone-accounts summary", text: "Accounts"
      install_input_log
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      find(".app-shell-phone-accounts summary").send_keys(:enter)
      opened = false
      40.times do
        opened = page.evaluate_script("document.querySelector('.app-shell-phone-accounts details').open")
        break if opened
        sleep 0.05
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      state = page.evaluate_script(STATE_JS)
      results << opened
      puts "DIAG attempt=#{i + 1} opened=#{opened} waited_ms=#{ms} #{state}"
    end
    puts "DIAG_SUMMARY attempts=#{ATTEMPTS} opened=#{results.count(true)} not_opened=#{results.count(false)}"
  end
end
