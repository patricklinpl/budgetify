require "test_helper"

# #63 REC-04 and REC-05 warnings (not Undo): saving or deleting a reconciled
# row asks first, writes nothing until confirmed, keeps typed values on Cancel,
# and keeps the row reconciled after a confirmed edit.
class ReconciledRowWarningTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Warn plan")
    @account = @budget.accounts.create!(name: "Savings", type: "savings")
    writer = TransactionWriter.new(@budget)
    @opening = add(writer, 100_000, "reconciled", "Opening")
    @pending = add(writer, -55_000, "uncleared", "Pending")
    @other = add(writer, 5_000, "cleared", "Plain")
  end

  def add(writer, amount, cleared, payee)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601,
      "amount" => amount, "payee_name" => payee, "cleared" => cleared))
  end

  def balances = @account.reload.then { |a| [ a.cleared_balance, a.uncleared_balance, a.balance ] }
  def path(txn) = users_budget_account_transaction_path(@budget.public_id, @account.public_id, txn.public_id)
  def params_for(txn, inflow:, extra: {}) = { transaction: { date: Date.current.iso8601, payee: txn.payee.name, category_id: "", memo: "", outflow: "", inflow: inflow } }.merge(extra)

  test "first save of a reconciled row writes nothing and shows the warning with the typed value" do
    before = balances
    patch path(@opening), params: params_for(@opening, inflow: "101")
    assert_response :unprocessable_entity
    assert_select "h2", text: "Save Changes to Reconciled Transaction"
    assert_select "p", text: /may bring your reconciliation out of balance/
    assert_select "input[name='transaction[inflow]'][value='101']"
    assert_equal before, balances
    assert_equal "reconciled", @opening.reload.cleared
  end

  test "cancel on the warning keeps the editor and the typed value and writes nothing" do
    before = balances
    patch path(@opening), params: params_for(@opening, inflow: "101", extra: { confirm_reconciled: "0" })
    assert_response :unprocessable_entity
    assert_select "h2", text: "Save Changes to Reconciled Transaction", count: 0
    assert_select "input[name='transaction[inflow]'][value='101']"
    assert_equal before, balances
  end

  test "confirmed save writes, recomputes balances and keeps the row reconciled" do
    patch path(@opening), params: params_for(@opening, inflow: "101", extra: { confirm_reconciled: "1" })
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal 101_000, @opening.reload.amount
    assert_equal "reconciled", @opening.cleared
    assert_equal [ 106_000, -55_000, 51_000 ], balances
  end

  test "invalid input on a reconciled row is rejected before any warning" do
    before = balances
    patch path(@opening), params: params_for(@opening, inflow: "1.005")
    assert_response :unprocessable_entity
    assert_select "h2", text: "Save Changes to Reconciled Transaction", count: 0
    assert_equal before, balances
  end

  test "a row that is not reconciled saves without a warning" do
    patch path(@other), params: params_for(@other, inflow: "6")
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal 6_000, @other.reload.amount
  end

  test "deleting a reconciled row asks first and writes nothing" do
    before = balances
    delete path(@opening)
    assert_response :unprocessable_entity
    assert_select "h1", text: "Delete Reconciled Transaction?"
    assert_select "p", text: /will bring the reconciliation out of balance/
    assert_select "a", text: "Cancel"
    assert_equal before, balances
    assert_not @opening.reload.deleted?
  end

  test "confirmed delete removes the reconciled row and recomputes balances" do
    delete path(@opening), params: { confirm_reconciled: "1" }
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal [ 5_000, -55_000, -50_000 ], balances
  end

  test "deleting a row that is not reconciled keeps today's single step" do
    delete path(@other)
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal [ 100_000, -55_000, 45_000 ], balances
  end

  test "another plan's reconciled row is a 404" do
    other = PlanLifecycle.create_plan(users(:two), name: "Other") rescue nil
    skip "second user fixture not available" unless other
    patch users_budget_account_transaction_path(other.public_id, @account.public_id, @opening.public_id), params: params_for(@opening, inflow: "9")
    assert_response :not_found
  end
end
