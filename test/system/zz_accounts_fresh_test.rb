require "application_system_test_case"

# [engineering] DIAGNOSTIC ONLY, not for merge. Hypothesis under test: the
# accounts keyboard step fails only on a fresh test (new plan, login, resize,
# visit, first Enter) and depends on browser state left by the previous test.
# Each generated test runs exactly the original test's step order with the same
# calls (resize_to, visit, assert_selector, install_input_log, send_keys,
# Capybara wait) and records the outcome and the previous test in this process
# instead of failing, so every attempt and its predecessor are kept.
class ZzAccountsFreshTest < ApplicationSystemTestCase
  COUNT = 30
  PREV = { name: "none" }

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 1400)
    PREV[:name] = name
  end

  STATE_JS = <<~JS
    (function () {
      var d = document.querySelector(".app-shell-phone-accounts details");
      var log = window.__inputLog || [];
      return JSON.stringify({
        open: d ? d.open : null,
        keydown: log.filter(function (l) { return /keydown Enter/.test(l); }).length,
        keyup: log.filter(function (l) { return /keyup Enter/.test(l); }).length,
        focus: document.hasFocus(), active: document.activeElement ? document.activeElement.tagName : "none",
        inner: [innerWidth, innerHeight], outer: [outerWidth, outerHeight],
        age: Math.round(performance.now())
      });
    })()
  JS

  COUNT.times do |n|
    test "fresh accounts keyboard step #{format('%02d', n + 1)}" do
      prev = PREV[:name]
      user = users(:one)
      plan = user.budgets.create!(name: "Household")
      visit users_sign_in_path
      fill_in "Email", with: user.email_address
      fill_in "Password", with: "password"
      click_button "Log in"
      assert_no_current_path users_sign_in_path
      plan.accounts.create!(name: "Everyday", type: "checking")
      plan.accounts.create!(name: "Rainy", type: "savings")
      page.driver.browser.manage.window.resize_to(390, 844)
      visit users_budget_path(plan.public_id)
      assert_selector ".app-shell-phone-accounts summary", text: "Accounts"
      install_input_log
      find(".app-shell-phone-accounts summary").send_keys(:enter)
      opened = begin
        assert_selector ".app-shell-phone-accounts__link", count: 2
        true
      rescue Minitest::Assertion, Capybara::ExpectationNotMet
        false
      end
      puts "DIAGFRESH #{name} opened=#{opened} prev=#{prev.inspect} #{page.evaluate_script(STATE_JS)}"
    end
  end
end
