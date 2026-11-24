require "application_system_test_case"

# Split editor in a real browser (#60 slice 3): native keys, the shared field
# controller (invalid text kept with an adjacent error, Save disabled), the
# mismatch state with Update Total, and a balanced save.
class SplitEditorSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Split plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    group = @plan.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @plan, name: "Zebra fund")
    @dining = group.categories.create!(budget: @plan, name: "Otter fund")
    writer = TransactionWriter.new(@plan)
    @transaction = writer.persist_new!(writer.build("date" => Date.current.iso8601, "amount" => -30_000, "account_id" => @account.public_id))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit edit_users_budget_account_transaction_split_path(@plan.public_id, @account.public_id, @transaction.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 6
  end

  test "invalid row text is kept with an adjacent error and Save is disabled" do
    field = find_field("split_rows_0_outflow")
    field.send_keys("abc", :enter)
    assert_selector "#split_rows_0_outflow-err", text: "Use numbers", visible: :visible
    assert_equal "true", field[:"aria-invalid"]
    assert_includes field[:"aria-describedby"].split, "split_rows_0_outflow-err"
    assert_equal "abc", field.value
    assert_button "Save split", disabled: true
  end

  test "a mismatch shows the remainder, Update Total sets the total, and a balanced save lands" do
    select "Zebra fund", from: "split_rows_0_category_id"
    find_field("split_rows_0_outflow").send_keys("10", :enter)
    select "Otter fund", from: "split_rows_1_category_id"
    find_field("split_rows_1_outflow").send_keys("15", :enter)
    click_button "Save split"
    assert_text "The split rows do not add up to the total."
    assert_text "Remainder"
    assert_no_text "Could not confirm the save"
    assert_equal 0, @transaction.reload.sub_transactions.count
    click_button "Update Total"
    assert_text "Total set to the split rows"
    assert_equal "25.00", find_field("split_outflow").value
    click_button "Save split"
    assert_text "Split saved."
    assert_equal(-25_000, @account.reload.balance)
    assert_equal 2, @transaction.reload.sub_transactions.count
  end
end
