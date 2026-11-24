require "application_system_test_case"

# Real browser run of the ordinary transaction editor (#60 slice 2): the money
# fields use the shared field controller (invalid text kept, adjacent accessible
# error, Save disabled while invalid), then a clean save lands in the register.
# Native key and click interactions only.
class RegisterTransactionEditorTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Register plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit new_users_budget_account_transaction_path(@plan.public_id, @account.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 2
  end

  test "invalid outflow text is kept with an adjacent accessible error and Save is disabled" do
    field = find_field("Outflow")
    assert_button "Save", disabled: false, exact: true
    field.send_keys("abc", :enter)
    assert_selector "#transaction_outflow-err", text: "Use numbers", visible: :visible
    assert_equal "true", field[:"aria-invalid"]
    assert_includes field[:"aria-describedby"].split, "transaction_outflow-err"
    assert_equal "abc", field.value
    assert_button "Save", disabled: true, exact: true
    sleep 0.3
    assert_equal 0, @account.transactions.count
  end

  test "an expression commits and Save adds the row to the register" do
    fill_in "Payee", with: "Corner Shop"
    select "Zebra fund", from: "Category"
    field = find_field("Outflow")
    field.send_keys("10+2.50")
    click_button "Save", exact: true
    assert_text "Transaction saved."
    assert_selector "td[data-label=Outflow]", text: "$12.50"
    assert_equal(-12_500, @account.reload.balance)
  end
end
