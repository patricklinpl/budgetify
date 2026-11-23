require "application_system_test_case"

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
      assert_selector ".app-shell-nav-item", count: 3
    end
    assert_equal "false", page.evaluate_script("localStorage.getItem('budgetify.sidebarCollapsed')")

    page.driver.browser.manage.window.resize_to(1400, 1000)
    assert_no_selector ".app-shell--collapsed"
    assert_selector ".app-shell-collapse"
  end
end
