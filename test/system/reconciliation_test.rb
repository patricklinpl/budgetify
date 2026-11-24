require "application_system_test_case"

# Real browser run of the reconcile flow (#63 REC-01, REC-02): invalid input
# keeps its text and writes nothing, Cancel writes nothing, and the adjustment
# path changes the balances only on the final button. Native clicks and keys.
class ReconciliationSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Reconcile plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    writer = TransactionWriter.new(@plan)
    [ [ 950_000, "cleared" ], [ -10_000, "uncleared" ] ].each do |amount, cleared|
      writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601,
        "amount" => amount, "payee_name" => "Shop", "cleared" => cleared))
    end
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def balances = @account.reload.then { |a| [ a.cleared_balance, a.uncleared_balance, a.balance ] }

  test "invalid balance keeps the text, cancel writes nothing, and the adjustment finishes" do
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
    click_link "Reconcile"
    assert_text "Is your account balance $950.00?"
    assert_selector "[data-controller~=field][data-field-ready=true]"

    fill_in "No, my balance is", with: "12.345"
    click_button "Review difference"
    assert_text "Use at most 2 decimal places (whole cents)"
    assert_field "No, my balance is", with: "12.345"
    assert_equal [ 950_000, -10_000, 940_000 ], balances
    assert_equal 0, @account.transactions.where(cleared: "reconciled").count

    fill_in "No, my balance is", with: "945"
    click_button "Review difference"
    assert_text "-$5.00"
    click_link "Cancel"
    assert_text "Is your account balance $950.00?"
    assert_equal [ 950_000, -10_000, 940_000 ], balances
    assert_equal 0, @account.transactions.where(cleared: "reconciled").count

    fill_in "No, my balance is", with: "945"
    click_button "Review difference"
    click_button "Create Adjustment & Finish"
    assert_text "Reconciled."
    assert_equal [ 945_000, -10_000, 935_000 ], balances
    assert_text "Uncleared"
    assert_no_text "Reconciliation Balance Adjustment"
    click_link "Show Reconciled"
    assert_text "Reconciliation Balance Adjustment"
    assert_text "Reconciled"
  end
end
