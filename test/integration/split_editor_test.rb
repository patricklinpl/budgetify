require "test_helper"

# Split editor (#60 slice 3). Numbers follow audit TX-SPLIT-01 to 04 in whole
# dollars. Effects follow the writer: the account moves by the parent once and
# each child moves its own category.
class SplitEditorTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "split@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Split plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    group = @budget.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @budget, name: "Groceries")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    @today = Date.current
    @month = @today.beginning_of_month
    post users_budget_account_transactions_path(@budget.public_id, @account.public_id),
      params: { transaction: { date: @today.iso8601, payee: "Mixed", category_id: @groceries.public_id, memo: "", outflow: "30", inflow: "" } }
    @transaction = @account.transactions.last
  end

  def split_path = users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)

  def activity(category) = category.month_categories.find_by(month: @month)&.activity.to_i

  def row(category, outflow: "", inflow: "", memo: "") = { category_id: category&.public_id.to_s, memo: memo, outflow: outflow, inflow: inflow }

  def split_params(total_outflow: "30", total_inflow: "", rows:, action: "save")
    { split_action: action, split: { outflow: total_outflow, inflow: total_inflow, rows: rows.each_with_index.to_h { |entry, index| [ index.to_s, entry ] } } }
  end

  test "the editor opens on an ordinary transaction with spare rows and the audit's unbuilt features stated" do
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    assert_response :success
    assert_select "input[name='split[outflow]'][value='30.00']"
    assert_select "select[name='split[rows][0][category_id]']"
    assert_select "select[name='split[rows][1][category_id]']"
    assert_select "button[name=split_action][value=save]"
    assert_select "p", text: /Auto-Distribute, split-transfer rows and undo are not built/
  end

  test "TX-SPLIT-01: splitting moves the account once and each child its own category" do
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-30_000, activity(@groceries))
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "20") ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-10_000, activity(@groceries))
    assert_equal(-20_000, activity(@dining))
    assert_nil @transaction.reload.category
    assert_equal [ [ -10_000, @groceries.id ], [ -20_000, @dining.id ] ], @transaction.sub_transactions.order(:id).pluck(:amount, :category_id)

    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    assert_select "input[name='split[rows][0][outflow]'][value='10.00']"
    assert_select "input[name='split[rows][1][outflow]'][value='20.00']"
  end

  test "TX-SPLIT-01: a mismatch shows the remainder and saves nothing, then Update Total and a second Save persist" do
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "20") ])
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "15") ])
    assert_response :unprocessable_entity
    assert_select "dd", text: "-$30.00"
    assert_select "dd", text: "-$25.00"
    assert_select "dd", text: "-$5.00"
    assert_select "[role=alert]", text: /Nothing was changed/
    assert_select "button[value=update_total]"
    assert_select "button[value=adjust]"
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-20_000, @transaction.reload.sub_transactions.order(:id).last.amount)

    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "15") ], action: "update_total")
    assert_response :success
    assert_select "input[name='split[outflow]'][value='25.00']"
    assert_equal(-30_000, @account.reload.balance)

    patch split_path, params: split_params(total_outflow: "25", rows: [ row(@groceries, outflow: "10"), row(@dining, outflow: "15") ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal(-25_000, @account.reload.balance)
    assert_equal(-25_000, @transaction.reload.amount)
    assert_equal(-10_000, activity(@groceries))
    assert_equal(-15_000, activity(@dining))
  end

  test "TX-SPLIT-03: Adjust Manually returns the editor with the typed values kept and saves nothing" do
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "20"), row(nil) ], action: "adjust")
    assert_response :success
    assert_select "input[name='split[rows][0][outflow]'][value='20']"
    assert_select "p[role=status]", text: /Nothing is saved yet/
    assert_equal 0, @transaction.reload.sub_transactions.count
    assert_equal(-30_000, @account.reload.balance)
  end

  test "TX-SPLIT-04: mixed signs save with zero remainder, keep both directions and do not touch the account" do
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "40"), row(@dining, inflow: "10") ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-40_000, activity(@groceries))
    assert_equal 10_000, activity(@dining)
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    assert_select "input[name='split[rows][0][outflow]'][value='40.00']"
    assert_select "input[name='split[rows][1][inflow]'][value='10.00']"
  end

  test "invalid input is refused with the typed text kept and nothing saved" do
    [ [ "abc", "10" ], [ "1.005", "28.995" ], [ "-5", "35" ] ].each do |first, second|
      patch split_path, params: split_params(rows: [ row(@groceries, outflow: first), row(@dining, outflow: second) ])
      assert_response :unprocessable_entity
      assert_select "input[name='split[rows][0][outflow]'][value=?]", first
      assert_select "[role=alert]", text: /Nothing was changed/
    end
    assert_equal 0, @transaction.reload.sub_transactions.count
    assert_equal(-30_000, @account.reload.balance)
    assert_equal(-30_000, activity(@groceries))
  end

  test "both directions on a row, an unknown category, a missing amount and no rows are refused" do
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "10", inflow: "5"), row(@dining, outflow: "20") ])
    assert_response :unprocessable_entity
    assert_select "p.field__error", text: /not both/

    patch split_path, params: split_params(rows: [ { category_id: "nope", memo: "", outflow: "30", inflow: "" } ])
    assert_response :unprocessable_entity
    assert_select "p.field__error", text: /Choose a category/

    patch split_path, params: split_params(rows: [ row(@groceries, memo: "no amount") ])
    assert_response :unprocessable_entity
    assert_select "p.field__error", text: /Enter an amount/

    patch split_path, params: split_params(rows: [ row(nil), row(nil) ])
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /at least one split row/
    assert_equal 0, @transaction.reload.sub_transactions.count
    assert_equal(-30_000, activity(@groceries))
  end

  test "blank rows are dropped and Add row adds one without saving" do
    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "30"), row(nil), row(nil) ])
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_equal 1, @transaction.reload.sub_transactions.count

    patch split_path, params: split_params(rows: [ row(@groceries, outflow: "30") ], action: "add_row")
    assert_response :success
    assert_select "select[name='split[rows][1][category_id]']"
  end

  test "a transfer cannot be split and another user's transaction is a 404" do
    transfer = @budget.transactions.new(account: @account, date: @today, amount: -5_000, transfer_account: @account)
    transfer.save!
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, transfer.public_id)
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_match(/Split transfers are not built/, flash[:alert])

    other = User.create!(email_address: "other-split@example.com", password: "password123")
    sign_in_as(other)
    get edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
    assert_response :not_found
  end
end
