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
    assert_button "Save and add another", disabled: true, exact: true
    sleep 0.3
    assert_equal 0, @account.transactions.count
    # Correcting the amount re-enables both submit buttons.
    field.send_keys([ :control, "a" ], :backspace, "5", :enter)
    assert_button "Save", disabled: false, exact: true
    assert_button "Save and add another", disabled: false, exact: true
  end

  test "a server refusal shows its message and not a could-not-confirm notice" do
    fill_in "Payee", with: "Corner Shop"
    find_field("Outflow").send_keys("5")
    find_field("Inflow").send_keys("7")
    click_button "Save", exact: true
    assert_text "Enter an outflow or an inflow, not both."
    assert_text "Nothing was changed."
    assert_no_text "Could not confirm the save"
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

  test "at phone width amounts and Edit are on screen without sideways page scroll" do
    @account.transactions.create!(budget: @plan, date: Date.current, amount: -12_340, payee: Payee.create!(budget: @plan, name: "Corner Shop"), category: @category)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    assert_selector "td[data-label=Outflow]", text: "$12.34"
    assert_equal false, page.evaluate_script("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    edit = find_link(href: /edit/)
    right = edit.native.rect.x + edit.native.rect.width
    height = edit.native.rect.height
    assert right <= 390, "Edit link is off screen at 390px (right edge #{right})"
    assert height >= 44, "Edit link is under 44px tall (#{height})"
  end
end
