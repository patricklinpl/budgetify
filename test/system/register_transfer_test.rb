require "application_system_test_case"

# Real browser run: a transfer is entered by typing a "To/From <account>" payee
# with native keys, saved, and the other account's register shows the matching
# row (#60 slice 4). Native key and click interactions only.
class RegisterTransferTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Transfer plan")
    @cash = @plan.accounts.create!(name: "Cash", type: "cash")
    @savings = @plan.accounts.create!(name: "Savings", type: "savings")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit new_users_budget_account_transaction_path(@plan.public_id, @cash.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 2
  end

  test "a To/From payee saves a transfer and the other account shows the matching row" do
    assert_selector "datalist#transaction_payee_options option[value='To/From Savings']", visible: :all
    select "Zebra fund", from: "Category"
    find_field("Payee").send_keys("To/From Savings")
    assert_field "Category", disabled: true, with: ""
    assert_select "Category", selected: "Category not needed", disabled: true
    find_field("Payee").send_keys(*Array.new(20, :backspace))
    assert_no_selector "select[disabled]"
    assert_select "Category", selected: "Zebra fund"
    assert_equal @category.public_id, find_field("Category").value
    find_field("Payee").send_keys("To/From Savings")
    find_field("Memo").send_keys("Top up")
    find_field("Outflow").send_keys("25", :enter)
    click_button "Save", exact: true
    assert_text "Transaction saved."
    assert_text "Transfer : Savings"
    assert_equal [ -25_000, 25_000 ], [ @cash.reload.balance, @savings.reload.balance ]

    visit users_budget_account_transactions_path(@plan.public_id, @savings.public_id)
    assert_text "Transfer : Cash"
    assert_text "Top up"
  end
end
