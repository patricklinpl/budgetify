require "application_system_test_case"

# Real browser run of the budget grid: the shared field controller validates
# and keeps rejected text, a clean commit saves, and the phone layout keeps
# every amount on screen with 44px controls.
class BudgetGridSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Grid plan")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_path(@plan.public_id)
  end

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  def assigned
    @category.reload.month_category_for(Date.current.beginning_of_month).budgeted.to_i
  end

  test "Enter commits an expression and saves it" do
    field = find_field("Assigned for Zebra fund")
    field.set("10+5*2")
    field.send_keys(:enter)
    assert_text "Zebra fund assigned $20.00."
    assert_equal 20_000, assigned
  end

  test "invalid text is kept with an inline error and nothing is saved; Escape restores" do
    field = find_field("Assigned for Zebra fund")
    field.set("0.004")
    field.send_keys(:enter)
    assert_text "Use at most 2 decimal places"
    assert_field "Assigned for Zebra fund", with: "0.004"
    assert_equal "true", find_field("Assigned for Zebra fund")["aria-invalid"]
    assert_equal 0, assigned
    find_field("Assigned for Zebra fund").send_keys(:escape)
    assert_field "Assigned for Zebra fund", with: "0.00"
  end

  test "phone layout keeps Activity visible with 44px controls and no sideways scroll" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_path(@plan.public_id)
    assert_selector "td[data-label=Activity]", minimum: 2, visible: true
    assert_equal false, page.evaluate_script("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    [ ".budget-grid input.field__input", ".budget-grid .btn", ".budget-grid td a" ].each do |selector|
      element = first(selector)
      assert_operator element.native.rect.height, :>=, 44, selector
    end
  end
end
