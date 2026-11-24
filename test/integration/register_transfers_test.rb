require "test_helper"

# Transfers and card payments in the register editor (#60 slice 4, TX-CASH-01,
# TX-PAY-01). The Payee field takes "To/From <account>", as in the reference.
# Checked in the reference test plan: the choice needs no category, the other
# account gets a matching row with the same memo, editing or deleting either
# side updates or removes both, and a payment into a card with no balance is
# allowed. Overpayment limits and split transfers are not covered.
class RegisterTransfersTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "transfers-ui@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Transfer plan")
    @cash = @budget.accounts.create!(name: "Cash", type: "cash")
    @savings = @budget.accounts.create!(name: "Savings", type: "savings")
    @card = @budget.accounts.create!(name: "CardA", type: "creditCard")
    group = @budget.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @budget, name: "Groceries")
    @today = Date.current
  end

  def list_path(account) = users_budget_account_transactions_path(@budget.public_id, account.public_id)

  def tx_path(account, transaction, action = nil)
    helper = action ? "#{action}_users_budget_account_transaction_path" : "users_budget_account_transaction_path"
    send(helper, @budget.public_id, account.public_id, transaction.public_id)
  end

  def params_for(payee, extra = {})
    { transaction: { date: @today.iso8601, payee: payee, category_id: "", memo: "moved", outflow: "25", inflow: "" }.merge(extra) }
  end

  def balances = [ @cash, @savings, @card ].map { |account| account.reload.balance }

  test "the payee field offers To/From entries for the other accounts only" do
    get new_users_budget_account_transaction_path(@budget.public_id, @cash.public_id)
    assert_select "datalist#transaction_payee_options option[value=?]", "To/From Savings"
    assert_select "datalist#transaction_payee_options option[value=?]", "To/From CardA"
    assert_select "datalist#transaction_payee_options option[value=?]", "To/From Cash", count: 0
    assert_select "input#transaction_payee[list=transaction_payee_options]"
  end

  test "a transfer saves with no category and moves equal and opposite amounts with the same memo" do
    assert_difference -> { Transaction.count }, 2 do
      post list_path(@cash), params: params_for("To/From Savings")
    end
    assert_redirected_to list_path(@cash)
    out = @cash.transactions.last
    pair = out.transfer_transaction
    assert_equal @savings.id, out.transfer_account_id
    assert_nil out.category
    assert_equal [ -25_000, 25_000 ], [ out.amount, pair.amount ]
    assert_equal [ "moved", "moved" ], [ out.memo, pair.memo ]
    assert_equal [ -25_000, 25_000, 0 ], balances
    follow_redirect!
    assert_select "td", text: "Transfer : Savings"
  end

  test "the account name match ignores case; an unknown name or the account itself is refused, nothing saved" do
    post list_path(@cash), params: params_for("to/from savings")
    assert_equal @savings.id, @cash.transactions.last.transfer_account_id

    [ "To/From Nowhere", "To/From Cash" ].each do |text|
      assert_no_difference -> { Transaction.count } do
        post list_path(@cash), params: params_for(text)
      end
      assert_response :unprocessable_entity
      assert_match(/no other open account with that name/, response.body)
      assert_match(/Nothing was changed/, response.body)
    end
  end

  test "a payee with characters the plan does not allow is refused instead of failing with a server error" do
    assert_no_difference -> { Transaction.count } do
      post list_path(@cash), params: params_for("Corner-Shop")
    end
    assert_response :unprocessable_entity
    assert_match(/Payee may only contain letters, numbers and spaces/, response.body)
  end

  test "a transfer with a category is refused and nothing is saved" do
    assert_no_difference -> { Transaction.count } do
      post list_path(@cash), params: params_for("To/From Savings", category_id: @groceries.public_id)
    end
    assert_response :unprocessable_entity
    assert_match(/does not use a category/, response.body)
    assert_match(/Nothing was changed/, response.body)
    assert_equal [ 0, 0, 0 ], balances
  end

  test "a card payment moves cash and the card, and paying a card with no balance is allowed" do
    post list_path(@cash), params: params_for("To/From CardA", outflow: "40")
    assert_equal [ -40_000, 0, 40_000 ], balances
    assert_equal 40_000, @card.transactions.last.amount
    assert_equal @cash.id, @card.transactions.last.transfer_account_id
  end

  test "editing from the counterpart side updates both rows, including the memo" do
    post list_path(@cash), params: params_for("To/From CardA", outflow: "40", memo: "Pay card")
    counterpart = @card.transactions.last
    get tx_path(@card, counterpart, :edit)
    assert_response :success
    assert_select "input#transaction_payee[value=?]", "To/From Cash"
    assert_select "input#transaction_inflow[value=?]", "40.00"

    patch tx_path(@card, counterpart), params: { transaction: { date: @today.iso8601, payee: "To/From Cash", category_id: "", memo: "Edited from card", outflow: "", inflow: "35" } }
    assert_redirected_to list_path(@card)
    original = @cash.transactions.last
    assert_equal [ -35_000, "Edited from card" ], [ original.reload.amount, original.memo ]
    assert_equal [ -35_000, 0, 35_000 ], balances
  end

  test "deleting either side removes both rows and restores the balances" do
    post list_path(@cash), params: params_for("To/From Savings")
    out = @cash.transactions.last
    pair = out.transfer_transaction
    get tx_path(@savings, pair, :edit)
    assert_match(/also removes the matching row in Cash/, response.body)

    delete tx_path(@savings, pair)
    assert out.reload.deleted
    assert pair.reload.deleted
    assert_equal [ 0, 0, 0 ], balances
  end

  test "changing a transfer to an ordinary payee unlinks and removes the counterpart" do
    post list_path(@cash), params: params_for("To/From Savings")
    out = @cash.transactions.last
    pair = out.transfer_transaction

    patch tx_path(@cash, out), params: params_for("Corner Shop", category_id: @groceries.public_id)
    assert_redirected_to list_path(@cash)
    assert_nil out.reload.transfer_account_id
    assert_equal @groceries.id, out.category_id
    assert pair.reload.deleted
    assert_equal [ -25_000, 0, 0 ], balances
  end

  test "an editor on a transfer shows the To/From entry, and a split still redirects" do
    post list_path(@cash), params: params_for("To/From Savings")
    get tx_path(@cash, @cash.transactions.last, :edit)
    assert_select "input#transaction_payee[value=?]", "To/From Savings"

    split = @budget.transactions.new(account: @cash, date: @today, amount: -10_000)
    split.save!
    split.sub_transactions.create!(amount: -10_000, category: @groceries)
    get tx_path(@cash, split, :edit)
    assert_redirected_to list_path(@cash)
    assert_match(/This transaction is a split/, flash[:alert])
  end
end
