require "test_helper"

# Account register and the ordinary transaction editor (#60 slice 2: TX-01,
# TX-ADD-ANOTHER-01, TX-EMPTY-01 as Peter chose: a fully blank save matches the
# reference and stores one zero-amount uncategorized row). Splits, transfers,
# payments, Undo and reload-time checks of the other slices are not asserted here.
class RegisterTransactionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "register@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Register plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    @other_account = @budget.accounts.create!(name: "Savings", type: "savings")
    group = @budget.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @budget, name: "Groceries")
    @today = Date.current
    @month = @today.beginning_of_month
  end


  def list_path = users_budget_account_transactions_path(@budget.public_id, @account.public_id)
  def new_path(**query) = new_users_budget_account_transaction_path(@budget.public_id, @account.public_id, **query)

  def activity
    @groceries.month_categories.find_by(month: @month)&.activity.to_i
  end

  def tx_path(transaction, action = nil)
    helper = action ? "#{action}_users_budget_account_transaction_path" : "users_budget_account_transaction_path"
    send(helper, @budget.public_id, @account.public_id, transaction.public_id)
  end

  def valid_params(extra = {})
    { transaction: { date: @today.iso8601, payee: "Corner Shop", category_id: @groceries.public_id, memo: "weekly", outflow: "12.50", inflow: "" }.merge(extra) }
  end

  test "an outflow with a category saves once and moves the account and category" do
    assert_difference -> { @account.transactions.count }, 1 do
      post list_path, params: valid_params
    end
    assert_redirected_to list_path
    transaction = @account.transactions.last
    assert_equal [ -12_500, "Corner Shop", @groceries.id, "weekly" ], [ transaction.amount, transaction.payee.name, transaction.category_id, transaction.memo ]
    assert_equal(-12_500, @account.reload.balance)
    assert_equal(-12_500, activity)
    follow_redirect!
    assert_select "td[data-label=Outflow]", text: "$12.50"
  end

  test "an inflow saves as a positive amount" do
    post list_path, params: valid_params(outflow: "", inflow: "100+20")
    assert_equal 120_000, @account.transactions.last.amount
    assert_equal 120_000, @account.reload.balance
  end

  test "an expression and whole cents: invalid text is refused, kept, and nothing is saved" do
    [ "abc", "1.005", "-5" ].each do |text|
      assert_no_difference -> { Transaction.count } do
        post list_path, params: valid_params(outflow: text)
      end
      assert_response :unprocessable_entity
      assert_select "input[name='transaction[outflow]'][value=?][aria-invalid=true]", text
      assert_select "#transaction_outflow-err[role=alert]", text: /\S/
      assert_select "[role=alert]", text: /Nothing was changed/
    end
    assert_equal 0, @account.reload.balance
  end

  test "entering both an outflow and an inflow is refused" do
    assert_no_difference -> { Transaction.count } do
      post list_path, params: valid_params(inflow: "5")
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /outflow or an inflow, not both/
  end

  test "a fully blank save stores one zero-amount uncategorized row and changes no balance (TX-EMPTY-01, Peter: match the reference)" do
    assert_difference -> { @account.transactions.count }, 1 do
      post list_path, params: { transaction: { date: @today.iso8601, payee: "", category_id: "", memo: "", outflow: "", inflow: "" } }
    end
    transaction = @account.transactions.last
    assert_equal [ 0, nil, nil ], [ transaction.amount, transaction.payee, transaction.category ]
    assert_equal 0, @account.reload.balance
  end

  test "Save and add another keeps the date, resets the rest, and saves exactly one row" do
    date = (@today - 3).iso8601
    assert_difference -> { @account.transactions.count }, 1 do
      post list_path, params: valid_params(date: date, outflow: "2.50", payee: "Cafe", category_id: "").merge(commit_action: "another")
    end
    assert_redirected_to new_path(date: date)
    follow_redirect!
    assert_select "input[name='transaction[date]'][value=?]", date
    assert_select "input[name='transaction[payee]'][value='']"
    assert_select "input[name='transaction[outflow]'][value='']"
    assert_equal(-2_500, @account.reload.balance)
  end

  test "future dates, bad dates and unknown categories are refused with nothing saved" do
    [ { date: (@today + 1).iso8601 }, { date: "2026-13-45" }, { category_id: "nope" } ].each do |bad|
      assert_no_difference -> { Transaction.count } do
        post list_path, params: valid_params(bad)
      end
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Nothing was changed/
    end
    assert_equal 0, @account.reload.balance
  end

  test "editing reverses the old effect and applies the new one, including clearing the category" do
    post list_path, params: valid_params
    transaction = @account.transactions.last
    patch tx_path(transaction), params: valid_params(outflow: "", inflow: "30", category_id: "", payee: "")
    assert_redirected_to list_path
    transaction.reload
    assert_equal [ 30_000, nil, nil ], [ transaction.amount, transaction.category, transaction.payee ]
    assert_equal 30_000, @account.reload.balance
    assert_equal 0, activity
  end

  test "editing keeps a flag the editor does not expose" do
    post list_path, params: valid_params
    transaction = @account.transactions.last
    transaction.update!(flag_color: "red", flag_name: "Check receipt")
    patch tx_path(transaction), params: valid_params(memo: "changed", outflow: "20")
    assert_redirected_to list_path
    transaction.reload
    assert_equal [ "changed", -20_000, "red", "Check receipt" ], [ transaction.memo, transaction.amount, transaction.flag_color, transaction.flag_name ]
  end

  test "a refused edit leaves the transaction, balance and activity unchanged" do
    post list_path, params: valid_params
    transaction = @account.transactions.last
    patch tx_path(transaction), params: valid_params(outflow: "abc")
    assert_response :unprocessable_entity
    assert_equal(-12_500, transaction.reload.amount)
    assert_equal(-12_500, @account.reload.balance)
    assert_equal(-12_500, activity)
  end

  test "delete reverses the effect and removes the row from the register" do
    post list_path, params: valid_params
    transaction = @account.transactions.last
    delete tx_path(transaction)
    assert_redirected_to list_path
    assert transaction.reload.deleted
    assert_equal 0, @account.reload.balance
    assert_equal 0, activity
    follow_redirect!
    assert_select "td", text: "Corner Shop", count: 0
  end

  test "a split or a transfer is shown but not editable here, and nothing changes" do
    split = @budget.transactions.new(account: @account, date: @today, amount: -10_000)
    split.save!
    split.sub_transactions.create!(amount: -10_000, category: @groceries)
    patch tx_path(split), params: valid_params(outflow: "1")
    assert_redirected_to list_path
    assert_match(/split or a transfer/, flash[:alert])
    assert_equal(-10_000, split.reload.amount)
    get tx_path(split, :edit)
    assert_redirected_to list_path
  end

  test "another user's plan, another plan's account and a transaction from a different account are a 404" do
    other = User.create!(email_address: "other-register@example.com", password: "password123")
    other_plan = PlanLifecycle.create_plan(other, name: "Theirs")
    other_account = other_plan.accounts.create!(name: "Theirs", type: "checking")
    get users_budget_account_transactions_path(other_plan.public_id, other_account.public_id)
    assert_response :not_found

    post list_path, params: valid_params
    transaction = @account.transactions.last
    get edit_users_budget_account_transaction_path(@budget.public_id, @other_account.public_id, transaction.public_id)
    assert_response :not_found
  end

  test "the register header links to the add and register pages" do
    get users_budget_path(@budget.public_id, account: @account.public_id)
    assert_select "a.shell-button", text: "Add Transaction"
    assert_select "a.shell-button", text: "Register"
  end
end
