require "test_helper"

# Characterization of the transfer and payment effects the audit observed
# (#60 TX-CASH-01 and TX-PAY-01), through the shared writer. It pins what the
# code does today; it does not add behaviour or decide product policy. Audit
# gaps (editing from the other side, overpayment, credit-positive) are
# deliberately not asserted here.
class TransactionTransferCharacterizationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "transfers@example.com", password: "password123")
    @plan = @user.budgets.create!(name: "Transfers plan")
    @cash = @plan.accounts.create!(name: "Cash", type: "cash")
    @savings = @plan.accounts.create!(name: "Savings", type: "savings")
    @card = @plan.accounts.create!(name: "CardA", type: "creditCard")
    group = @plan.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @plan, name: "Groceries")
    @writer = TransactionWriter.new(@plan)
    @today = Date.current
  end

  def put(account, amount, extra = {})
    @writer.persist_new!(@writer.build({ "account_id" => account.public_id, "date" => @today.iso8601, "amount" => amount }.merge(extra)))
  end

  # TX-CASH-01 (T): Savings 100 / Cash -300, transfer 25 Savings -> Cash.
  test "a transfer needs no category and moves equal and opposite amounts with the same memo" do
    put(@savings, 100_000)
    put(@cash, -300_000)
    out = put(@savings, -25_000, "transfer_account_id" => @cash.public_id, "memo" => "Top up")
    pair = out.reload.transfer_transaction

    assert_nil out.category
    assert_equal 75_000, @savings.reload.balance
    assert_equal(-275_000, @cash.reload.balance)
    assert_equal(-200_000, @savings.balance + @cash.balance)
    assert_equal(-out.amount, pair.amount)
    assert_equal @cash.id, pair.account_id
    assert_equal out.id, pair.transfer_transaction_id
    assert_equal "Top up", pair.memo
    assert_equal pair.id, out.transfer_transaction_id
  end

  # The audit observed the same memo on both rows (TX-CASH-01, TX-PAY-01). The
  # counterpart gets the memo on create and follows later edits, including
  # clearing it.
  test "the counterpart row carries the same memo and follows memo edits" do
    out = put(@savings, -25_000, "transfer_account_id" => @cash.public_id, "memo" => "Top up")
    pair = out.reload.transfer_transaction
    assert_equal "Top up", pair.memo

    Transaction.transaction { @writer.update!(out, { "memo" => "Rent top up" }, rebuild_subs: false) }
    assert_equal "Rent top up", pair.reload.memo

    Transaction.transaction { @writer.update!(out, { "memo" => nil }, rebuild_subs: false) }
    assert_nil pair.reload.memo
  end

  # TX-PAY-01 (T): Cash 965, CardA -100, payment 40 => 925 / -60; edit to 35 =>
  # 930 / -65; delete the cash side => 965 / -100 and the counterpart is gone.
  test "a card payment moves cash and the card, follows an edit, and deleting the cash side removes the counterpart" do
    put(@cash, 965_000)
    put(@card, -100_000)
    payment = put(@cash, -40_000, "transfer_account_id" => @card.public_id, "memo" => "Pay card")
    pair = payment.reload.transfer_transaction

    assert_equal 925_000, @cash.reload.balance
    assert_equal(-60_000, @card.reload.balance)
    assert_equal 40_000, pair.amount
    assert_equal @card.id, pair.account_id

    Transaction.transaction { @writer.update!(payment, { "amount" => -35_000 }, rebuild_subs: false) }
    assert_equal 930_000, @cash.reload.balance
    assert_equal(-65_000, @card.reload.balance)
    assert_equal 35_000, pair.reload.amount

    Transaction.transaction { @writer.destroy!(payment) }
    assert_equal 965_000, @cash.reload.balance
    assert_equal(-100_000, @card.reload.balance)
    assert pair.reload.deleted
    assert_equal 2, @plan.transactions.not_deleted.count, "the two opening rows remain"
  end

  # TX-PAY-01 (T): the payment category had 100 available from funded card
  # spending and 60 after the 40 payment. Setup: Groceries has 100 assigned, a
  # 100 card purchase in Groceries funds the card's payment category, then pay 40.
  test "[reference T 100 to 60; engineering 65 and 100 after edit and delete] the card payment category after a 40 payment, its edit and its delete" do
    month = @today.beginning_of_month
    @groceries.month_category_for(month).update!(budgeted: 100_000)
    put(@cash, 965_000)
    put(@card, -100_000, "category_id" => @groceries.public_id)
    payment_category = @card.reload.payment_category
    available = -> { CategorySerializer.as_json(payment_category.reload, month: month)[:balance] }
    assert_equal 100_000, available.call

    payment = put(@cash, -40_000, "transfer_account_id" => @card.public_id)
    assert_equal 60_000, available.call

    # Edit to 35 gives 65 available; deleting the cash side puts it back to 100
    # and the card purchase remains (engineering extension of the same fixture).
    Transaction.transaction { @writer.update!(payment, { "amount" => -35_000 }, rebuild_subs: false) }
    assert_equal 65_000, available.call
    Transaction.transaction { @writer.destroy!(payment) }
    assert_equal 100_000, available.call
    assert_equal(-100_000, @card.reload.balance)
    assert_equal 1, @plan.transactions.not_deleted.where(account: @card).count, "the card purchase remains"
  end
end
