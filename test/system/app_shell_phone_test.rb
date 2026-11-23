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

  test "accounts stay reachable at 390px by click and keyboard and select the account route" do
    checking = @plan.accounts.create!(name: "Everyday", type: "checking")
    @plan.accounts.create!(name: "Rainy", type: "savings")
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_path(@plan.public_id)
    assert_selector ".app-shell-phone-accounts summary", text: "Accounts"
    find(".app-shell-phone-accounts summary").send_keys(:enter)
    assert_selector ".app-shell-phone-accounts__link", count: 2
    link = find(".app-shell-phone-accounts__link", text: "Everyday")
    assert_operator link.native.rect.width, :>=, 44
    assert_operator link.native.rect.height, :>=, 44
    link.click
    assert_current_path users_budget_path(@plan.public_id, account: checking.public_id)
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
