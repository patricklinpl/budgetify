require "application_system_test_case"

# Real browser run of the monthly target field (#58 TARGET-01, partial): the
# shared field controller (FRM-02, FRM-05) validates and keeps rejected text,
# the error sits next to the field with aria-invalid and aria-describedby, the
# submit button is disabled while the field is invalid, and a clean commit
# saves. Native key and click interactions only.
class MonthlyTargetSystemTest < ApplicationSystemTestCase
  setup do
    # Sign-in is rate limited per process (10 per 3 minutes); start this test
    # with a fresh counter so UI logins from other system tests cannot trip it.
    Rails.cache.clear
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Target plan")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit target_users_budget_category_path(@plan.public_id, @category.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]"
  end

  test "invalid text is kept with an adjacent accessible error, Save is disabled, nothing is saved" do
    field = find_field("Set aside every month")
    assert_button "Create target", disabled: true
    field.send_keys("abc", :enter)
    assert_selector "#target_amount-err", text: "Use numbers", visible: :visible
    assert_equal "true", field[:"aria-invalid"]
    assert_includes field[:"aria-describedby"].split, "target_amount-err"
    assert_equal "abc", field.value
    assert_button "Create target", disabled: true
    sleep 0.3
    assert_nil @category.reload.goal_target

    field.send_keys([ :control, "a" ], :backspace, "1.005", :enter)
    assert_selector "#target_amount-err", text: "2 decimal places"
    assert_equal "1.005", field.value
    assert_button "Create target", disabled: true
    assert_nil @category.reload.goal_target
  end

  test "typing again clears the error, Enter evaluates the expression and saves it" do
    field = find_field("Set aside every month")
    field.send_keys("abc", :enter)
    assert_selector "#target_amount-err", text: "Use numbers"
    field.send_keys([ :control, "a" ], :backspace, "100+100")
    assert_no_selector "#target_amount-err", visible: :visible
    assert_nil field[:"aria-invalid"]
    assert_button "Create target", disabled: false
    field.send_keys(:enter)
    assert_text "Target saved."
    assert_equal 200_000, @category.reload.goal_target
  end

  test "Escape restores the committed text" do
    field = find_field("Set aside every month")
    field.send_keys("50", :escape)
    assert_equal "", field.value
  end

  test "another kind of target shows no editor field" do
    @category.update!(goal_type: "TB", goal_target: 300_000)
    visit target_users_budget_category_path(@plan.public_id, @category.public_id)
    assert_no_field "Set aside every month"
    assert_text "does not support"
  end
end
