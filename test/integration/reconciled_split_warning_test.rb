require "test_helper"

# Reconciled split parent (follow-up to #132). Reference checks: changing the
# parent total warns; a memo-only edit, or moving amounts between children at
# the same total, saves without the warning. Mismatches and invalid input are
# refused before any warning.
class ReconciledSplitWarningTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "recsplit@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Rec split plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    group = @budget.category_groups.create!(name: "Everyday")
    @bills = group.categories.create!(budget: @budget, name: "Bills")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    post users_budget_account_transactions_path(@budget.public_id, @account.public_id),
      params: { transaction: { date: Date.current.iso8601, payee: "", category_id: "", memo: "", outflow: "20", inflow: "" } }
    @transaction = @account.transactions.last
    patch split_path, params: split_params(rows: [ row(@bills, outflow: "12"), row(@dining, outflow: "8") ])
    @transaction.update_columns(cleared: "reconciled")
  end

  def split_path = users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
  def row(category, outflow: "", memo: "") = { category_id: category.public_id, memo: memo, outflow: outflow, inflow: "" }

  def split_params(total: "20", rows:, extra: {})
    { split_action: "save", split: { outflow: total, inflow: "", rows: rows.each_with_index.to_h { |entry, index| [ index.to_s, entry ] } } }.merge(extra)
  end

  def children = @transaction.reload.sub_transactions.order(:id).pluck(:amount)
  def memo = @transaction.reload.memo.to_s

  test "changing the parent total of a reconciled split asks first and writes nothing" do
    patch split_path, params: split_params(total: "25", rows: [ row(@bills, outflow: "15"), row(@dining, outflow: "10") ])
    assert_response :unprocessable_entity
    assert_select "section.plan-settings__warning h2", text: "Save Changes to Reconciled Transaction"
    assert_select "input[name='split[outflow]'][value='25']"
    assert_equal(-20_000, @transaction.reload.amount)
    assert_equal [ -12_000, -8_000 ], children
    assert_equal "reconciled", @transaction.cleared
  end

  test "Cancel on the warning keeps the typed values and writes nothing, Save writes and stays reconciled" do
    rows = [ row(@bills, outflow: "15"), row(@dining, outflow: "10") ]
    patch split_path, params: split_params(total: "25", rows: rows, extra: { confirm_reconciled: "0" })
    assert_response :unprocessable_entity
    assert_select "section.plan-settings__warning", count: 0
    assert_select "input[name='split[outflow]'][value='25']"
    assert_equal(-20_000, @transaction.reload.amount)

    patch split_path, params: split_params(total: "25", rows: rows, extra: { confirm_reconciled: "1" })
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal(-25_000, @transaction.reload.amount)
    assert_equal [ -15_000, -10_000 ], children
    assert_equal "reconciled", @transaction.cleared
  end

  test "moving amounts between children at the same total saves without the warning" do
    patch split_path, params: split_params(rows: [ row(@bills, outflow: "15"), row(@dining, outflow: "5") ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal [ -15_000, -5_000 ], children
    assert_equal(-20_000, @transaction.reload.amount)
    assert_equal "reconciled", @transaction.cleared
  end

  test "a total typed differently but equal is not a change" do
    patch split_path, params: split_params(total: "20.00", rows: [ row(@bills, outflow: "12"), row(@dining, outflow: "8", memo: "m") ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal "m", @transaction.reload.sub_transactions.order(:id).last.memo
  end

  test "a mismatch is refused before the warning, and invalid input too" do
    patch split_path, params: split_params(total: "25", rows: [ row(@bills, outflow: "12"), row(@dining, outflow: "8") ])
    assert_response :unprocessable_entity
    assert_select "section.plan-settings__warning", count: 0
    assert_select ".split-editor__mismatch"
    patch split_path, params: split_params(total: "2x", rows: [ row(@bills, outflow: "12"), row(@dining, outflow: "8") ])
    assert_response :unprocessable_entity
    assert_select "section.plan-settings__warning", count: 0
    assert_equal(-20_000, @transaction.reload.amount)
  end

  test "the editor carries the guard with the stored total and the dialog, an unreconciled split does not" do
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    initial = JSON.parse(css_select("form[data-controller~='reconcile-guard']").first["data-reconcile-guard-initial-value"])
    assert_equal({ "split[outflow]" => "20.00", "split[inflow]" => "" }, initial)
    assert_select "dialog#dlg-reconciled-save h2", text: "Save Changes to Reconciled Transaction"
    assert_select "button[data-reconcile-guard-save]", text: "Save split"
    @transaction.update_columns(cleared: "cleared")
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    assert_select "dialog", count: 0
    assert_select "button[type=submit][value=save]", text: "Save split"
  end
end
