require "application_system_test_case"

# Browser checks for plan settings (issue #54): Cancel keeps the saved name,
# and Fresh Start only runs after confirmation.
class PlanSettingsSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = @user.budgets.create!(name: "Household")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  test "PLAN-CANCEL-01 typing a different name then Cancel keeps the saved name" do
    visit settings_users_budget_path(@plan.public_id)
    fill_in "Plan name", with: "Something else"
    click_link "Cancel"

    assert_current_path users_budget_path(@plan.public_id)
    assert_selector ".app-shell-plan-name", text: "Household"
    assert_equal "Household", @plan.reload.name
    visit users_budgets_path
    assert_selector ".budget-selection-name", text: "Household"
  end

  test "Fresh Start dialog Cancel creates nothing and Confirm creates the new plan" do
    visit settings_users_budget_path(@plan.public_id)
    assert_no_difference -> { @user.budgets.count } do
      click_button "Fresh Start…"
      assert_selector "dialog[open] .dialog__title", text: "Start fresh"
      within("dialog[open]") { click_button "Cancel" }
      assert_no_selector "dialog[open]"
      sleep 0.3
    end
    assert_equal "Household", @plan.reload.name

    click_button "Fresh Start…"
    within("dialog[open]") { click_button "Create fresh plan" }
    assert_text "Fresh Start created a new plan"
    assert_equal PlanLifecycle.archived_name("Household"), @plan.reload.name
    assert_equal 2, @user.budgets.count
  end
end
