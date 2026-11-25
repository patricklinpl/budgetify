require "test_helper"

# #60 verification gaps (partial). Each test names the audit ID it checks and
# whether the number comes from the reference (T) or is an engineering check.
# The other IDs are covered in split_editor_test, register_transactions_test,
# register_transfers_test and transaction_transfer_characterization_test.
# TX-SPLIT-02 (Auto-Distribute) is held and not built here.
class TransactionEditorVerificationTest < ActionDispatch::IntegrationTest
  TURBO = { "X-Turbo-Request-Id" => "t1" }.freeze

  setup do
    @user = User.create!(email_address: "verify60@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Verify plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    group = @budget.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @budget, name: "Groceries")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    @today = Date.current
    @month = @today.beginning_of_month
  end

  def list_path = users_budget_account_transactions_path(@budget.public_id, @account.public_id)

  def add(outflow: "", inflow: "", payee: "Shop", category: nil, extra: {})
    post list_path, params: { transaction: { date: @today.iso8601, payee: payee, category_id: category&.public_id.to_s, memo: "", outflow: outflow, inflow: inflow } }.merge(extra), headers: TURBO
    @account.transactions.order(:id).last
  end

  def split_path(transaction) = users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, transaction.public_id)

  def activity(category) = category.month_categories.find_by(month: @month)&.activity.to_i

  def row(category, outflow: "", inflow: "") = { category_id: category&.public_id.to_s, memo: "", outflow: outflow, inflow: inflow }

  def split_params(total_outflow: "30", rows:, action: "save")
    { split_action: action, split: { outflow: total_outflow, inflow: "", rows: rows.each_with_index.to_h { |entry, index| [ index.to_s, entry ] } } }
  end

  test "[reference T] TX-SPLIT-03: a mismatch of 10 is refused, Adjust Manually keeps the values, and filling the second row with 10 saves 20 + 10" do
    parent = add(outflow: "30", category: @groceries)
    patch split_path(parent), params: split_params(rows: [ row(@groceries, outflow: "20"), row(nil) ])
    assert_response :unprocessable_entity
    assert_select "dd", text: "-$10.00"
    assert_equal 0, parent.reload.sub_transactions.count
    assert_equal(-30_000, @account.reload.balance)

    patch split_path(parent), params: split_params(rows: [ row(@groceries, outflow: "20"), row(nil) ], action: "adjust")
    assert_response :success
    assert_select "input[name='split[rows][0][outflow]'][value='20']"
    assert_equal 0, parent.reload.sub_transactions.count

    patch split_path(parent), params: split_params(rows: [ row(@groceries, outflow: "20"), row(@dining, outflow: "10") ])
    assert_redirected_to list_path
    assert_equal(-30_000, parent.reload.amount)
    assert_equal [ -20_000, -10_000 ], parent.sub_transactions.order(:id).pluck(:amount)
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-20_000, activity(@groceries))
    assert_equal(-10_000, activity(@dining))
  end

  test "[reference T] TX-SPLIT-04: with a separate 3.21 expense, Groceries activity is -43.21 and Dining +10 (children are not both outflows)" do
    parent = add(outflow: "30", category: @groceries)
    add(outflow: "3.21", category: @groceries, payee: "Separate")
    balance_before = @account.reload.balance
    assert_equal(-33_210, balance_before)

    patch split_path(parent), params: split_params(rows: [ row(@groceries, outflow: "40"), row(@dining, inflow: "10") ])
    assert_redirected_to list_path
    assert_equal balance_before, @account.reload.balance
    assert_equal(-43_210, activity(@groceries))
    assert_equal 10_000, activity(@dining)
  end

  test "[reference T] TX-ADD-ANOTHER-01: save-and-add-another then leaving the blank editor keeps the row; Undo removes only that row and restores 45" do
    add(inflow: "45", payee: "Start")
    assert_equal 45_000, @account.reload.balance
    assert_difference -> { @account.transactions.count }, 1 do
      add(outflow: "2.50", payee: "Cafe", extra: { commit_action: "another" })
    end
    assert_equal 42_500, @account.reload.balance
    # Omitted category is allowed and flagged for categorization (engineering placement).
    get list_path, headers: TURBO
    assert_select "p[role=status]", text: "1 transaction needs a category."
    assert_select "td[data-label=Category]", text: "Needs a category", count: 1

    # The fresh form after Save and add another: date kept, everything else reset.
    kept = (@today - 3).iso8601
    post list_path, params: { transaction: { date: kept, payee: "Second", category_id: @dining.public_id.to_s, memo: "note", outflow: "1", inflow: "" }, commit_action: "another" }, headers: TURBO
    assert_equal 41_500, @account.reload.balance
    assert_redirected_to new_users_budget_account_transaction_path(@budget.public_id, @account.public_id, date: kept)
    get response.location, headers: TURBO
    assert_select "input[name='transaction[date]'][value=?]", kept
    assert_select "input[name='transaction[payee]'][value='']"
    assert_select "input[name='transaction[memo]'][value='']"
    assert_select "input[name='transaction[outflow]'][value='']"
    assert_select "input[name='transaction[inflow]'][value='']"
    assert_select "select[name='transaction[category_id]'] option[selected][value]:not([value=''])", count: 0
    # Leave the blank editor: nothing extra is written.
    get list_path, headers: TURBO
    assert_equal 3, @account.transactions.not_deleted.count
    # Undo steps back through "Second" first, then "Cafe".
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal 42_500, @account.reload.balance
    assert_equal 2, @account.transactions.not_deleted.count

    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal 45_000, @account.reload.balance
    assert_equal [ "Start" ], @account.transactions.not_deleted.map { |t| t.payee&.name || t.payee }.map(&:to_s)
    get list_path, headers: TURBO
    assert_select "body", text: /Start/
    assert_select "body", text: /Cafe/, count: 0
    assert_select "p[role=status]", text: /needs a category/, count: 0
  end

  test "[reference T] TX-EMPTY-01: the blank zero-amount row is flagged as needing a category and Undo removes it (Peter chose to match the reference)" do
    assert_difference -> { @account.transactions.count }, 1 do
      add
    end
    assert_equal 0, @account.reload.balance
    get list_path, headers: TURBO
    assert_select "p[role=status]", text: "1 transaction needs a category."
    assert_select "td[data-label=Category]", text: "Needs a category", count: 1
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    get list_path, headers: TURBO
    assert_select "p[role=status]", text: /needs a category/, count: 0
    assert_equal 0, @account.transactions.not_deleted.count
    assert_equal 0, @account.reload.balance
  end
  test "[engineering] categorized rows, inflows, splits and transfers are not flagged; an uncategorized outflow is, and a tracking account never is" do
    savings = @budget.accounts.create!(name: "Savings", type: "savings")
    add(outflow: "5", category: @groceries, payee: "Categorized")
    add(inflow: "20", payee: "Refund")
    split_parent = add(outflow: "30", category: @groceries, payee: "Parent")
    patch split_path(split_parent), params: split_params(rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "20") ])
    add(outflow: "1", payee: "To/From Savings")
    assert_equal savings.id, @account.transactions.not_deleted.order(:id).last.transfer_account_id
    get list_path, headers: TURBO
    assert_select "p[role=status]", text: /needs a category/, count: 0
    assert_select "td[data-label=Category]", text: "Needs a category", count: 0

    add(outflow: "2", payee: "Plain")
    get list_path, headers: TURBO
    assert_select "p[role=status]", text: "1 transaction needs a category."
    assert_select "td[data-label=Category]", text: "Needs a category", count: 1

    tracking = @budget.accounts.create!(name: "House", type: "otherAsset", on_budget: false)
    assert tracking.tracking?
    post users_budget_account_transactions_path(@budget.public_id, tracking.public_id), params: { transaction: { date: @today.iso8601, payee: "Bill", category_id: "", memo: "", outflow: "3", inflow: "" } }, headers: TURBO
    get users_budget_account_transactions_path(@budget.public_id, tracking.public_id), headers: TURBO
    assert_select "p[role=status]", text: /needs a category/, count: 0
    assert_select "td[data-label=Category]", text: "Needs a category", count: 0
  end

  def edit_params(transaction, **fields)
    { transaction: { date: @today.iso8601, payee: transaction.payee.to_s, category_id: transaction.category&.public_id.to_s, memo: "" }.merge(fields) }
  end

  test "[engineering] TX-01 Cancel: the new and edit forms link back to the register, and leaving them writes nothing" do
    transaction = add(outflow: "12", category: @groceries, payee: "Keep")
    before = [ @account.reload.balance, @account.transactions.not_deleted.count, activity(@groceries) ]
    get new_users_budget_account_transaction_path(@budget.public_id, @account.public_id), headers: TURBO
    assert_select "a.btn[href=?]", list_path, text: "Cancel"
    get edit_users_budget_account_transaction_path(@budget.public_id, @account.public_id, transaction.public_id), headers: TURBO
    assert_select "a.btn[href=?]", list_path, text: "Cancel"
    get list_path, headers: TURBO
    assert_response :success
    assert_equal before, [ @account.reload.balance, @account.transactions.not_deleted.count, activity(@groceries) ]
  end

  test "[engineering] TX-01 edit directions: outflow to inflow and inflow to outflow reverse and reapply with exact balances" do
    transaction = add(outflow: "20", category: @groceries, payee: "Flip")
    assert_equal [ -20_000, -20_000 ], [ @account.reload.balance, activity(@groceries) ]
    patch users_budget_account_transaction_path(@budget.public_id, @account.public_id, transaction.public_id), params: edit_params(transaction, outflow: "", inflow: "8"), headers: TURBO
    assert_equal [ 8_000, 8_000 ], [ @account.reload.balance, activity(@groceries) ]
    assert_equal 8_000, transaction.reload.amount
    patch users_budget_account_transaction_path(@budget.public_id, @account.public_id, transaction.public_id), params: edit_params(transaction, outflow: "5", inflow: ""), headers: TURBO
    assert_equal [ -5_000, -5_000 ], [ @account.reload.balance, activity(@groceries) ]
    assert_equal(-5_000, transaction.reload.amount)
  end
end
