require "application_system_test_case"

# Real browser run of the reconciled-row warnings (#63 REC-04/05 warnings).
class ReconciledRowWarningSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Warn plan")
    @account = @plan.accounts.create!(name: "Savings", type: "savings")
    writer = TransactionWriter.new(@plan)
    [ [ 100_000, "reconciled", "Opening" ], [ -55_000, "uncleared", "Pending" ] ].each do |amount, cleared, payee|
      writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601,
        "amount" => amount, "payee_name" => payee, "cleared" => cleared))
    end
    @opening = @account.transactions.find_by!(amount: 100_000)
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def balances = @account.reload.then { |a| [ a.cleared_balance, a.uncleared_balance, a.balance ] }

  test "warning cancel keeps the typed value, confirm saves, and delete asks first" do
    visit edit_users_budget_account_transaction_path(@plan.public_id, @account.public_id, @opening.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]"
    fill_in "Inflow", with: "101"
    click_button "Save", exact: true
    assert_selector "dialog[open] h2", text: "Save Changes to Reconciled Transaction"
    assert_equal [ 100_000, -55_000, 45_000 ], balances
    within("dialog[open]") { click_button "Cancel" }
    assert_no_selector "dialog[open]"
    assert_field "Inflow", with: "101"
    assert_equal [ 100_000, -55_000, 45_000 ], balances

    click_button "Save", exact: true
    assert_selector "dialog[open] h2", text: "Save Changes to Reconciled Transaction"
    within("dialog[open]") { click_button "Save" }
    assert_text "Transaction saved."
    assert_equal [ 101_000, -55_000, 46_000 ], balances
    assert_equal "reconciled", @opening.reload.cleared

    visit edit_users_budget_account_transaction_path(@plan.public_id, @account.public_id, @opening.public_id)
    click_button "Delete transaction"
    assert_selector "dialog[open] h2", text: "Delete Reconciled Transaction?"
    assert_equal [ 101_000, -55_000, 46_000 ], balances
    within("dialog[open]") { click_button "Cancel" }
    assert_no_selector "dialog[open]"
    assert_selector "h1", text: "Edit transaction"
    click_button "Delete transaction"
    within("dialog[open]") { click_button "Delete" }
    assert_text "Transaction deleted."
    assert_equal [ 0, -55_000, -55_000 ], balances
  end
end
