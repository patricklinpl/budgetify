require "test_helper"

# Undo slice 1: history storage, recording through TransactionWriter, the
# inverse, the field-level stale check, ordering and the size and depth limits.
class UndoHistoryTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @budget = PlanLifecycle.create_plan(@user, name: "Undo plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    @other_account = @budget.accounts.create!(name: "Savings", type: "savings")
    @category = @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).first
    @history = history
    @writer = TransactionWriter.new(@budget, history: @history)
  end

  def history(token: "tok", session_key: "s1") = UndoHistory.new(user: @user, budget: @budget, session_key: session_key, token: token)

  def balances = [ @account, @other_account ].map { |a| a.reload.then { |x| [ x.cleared_balance, x.uncleared_balance, x.balance ] } }

  def activity = @category ? @category.month_categories.sum(:activity) : 0

  def create_tx(amount: -10_000, cleared: "uncleared", extra: {})
    Transaction.transaction do
      @writer.persist_new!(@writer.build({ "account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => amount,
        "payee_name" => "Shop", "cleared" => cleared, "category_id" => @category&.public_id }.merge(extra)))
    end
  end

  def edit_tx(tx, attrs, rebuild_subs: false)
    Transaction.transaction { @writer.update!(tx, { "flag_color" => tx.flag_color, "flag_name" => tx.flag_name }.merge(attrs), rebuild_subs: rebuild_subs) }
  end

  def delete_tx(tx) = Transaction.transaction { @writer.destroy!(tx) }

  test "starts with nothing to undo or redo" do
    assert_not @history.can_undo?
    assert_not @history.can_redo?
  end

  test "create undoes and redoes with exact balances and category activity" do
    base = balances
    base_activity = activity
    tx = create_tx
    after = balances
    after_activity = activity
    assert_not_equal base, after
    assert @history.can_undo?

    @history.undo!
    assert_equal base, balances
    assert_equal base_activity, activity
    assert tx.reload.deleted
    assert_not @history.can_undo?
    assert @history.can_redo?

    @history.redo!
    assert_equal after, balances
    assert_equal after_activity, activity
    assert_not tx.reload.deleted
  end

  test "edit undoes and redoes" do
    tx = create_tx
    first = balances
    edit_tx(tx, { "amount" => -25_000, "memo" => "changed" })
    second = balances
    assert_equal(-25_000, tx.reload.amount)

    @history.undo!
    assert_equal first, balances
    assert_equal(-10_000, tx.reload.amount)
    assert_nil tx.memo
    @history.redo!
    assert_equal second, balances
    assert_equal "changed", tx.reload.memo
  end

  test "delete undoes and redoes" do
    tx = create_tx
    live = balances
    delete_tx(tx)
    gone = balances
    @history.undo!
    assert_equal live, balances
    assert_not tx.reload.deleted
    @history.redo!
    assert_equal gone, balances
    assert tx.reload.deleted
  end

  test "a linked transfer undoes and redoes as one step on both sides" do
    base = balances
    tx = create_tx(amount: -20_000, extra: { "transfer_account_id" => @other_account.public_id, "category_id" => nil })
    pair = tx.reload.transfer_transaction
    moved = balances
    assert pair
    @history.undo!
    assert_equal base, balances
    assert tx.reload.deleted && pair.reload.deleted
    @history.redo!
    assert_equal moved, balances
    assert_not tx.reload.deleted || pair.reload.deleted
  end

  test "deleting a split parent undoes with its children" do
    other = @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).second
    tx = create_tx(amount: -30_000, extra: { "category_id" => nil, "subtransactions" => [
      { "amount" => -10_000, "category_id" => @category.public_id }, { "amount" => -20_000, "category_id" => (other || @category).public_id }
    ] })
    live = balances
    live_activity = activity
    delete_tx(tx)
    @history.undo!
    assert_equal live, balances
    assert_equal live_activity, activity
    assert_equal 2, tx.reload.sub_transactions.not_deleted.count
    @history.redo!
    assert tx.reload.deleted
  end

  test "editing a split rebuilds children and undo restores the originals" do
    tx = create_tx(amount: -30_000, extra: { "category_id" => nil, "subtransactions" => [
      { "amount" => -10_000, "category_id" => @category.public_id }, { "amount" => -20_000, "category_id" => @category.public_id }
    ] })
    before_ids = tx.sub_transactions.pluck(:id).sort
    base = balances
    base_activity = activity
    edit_tx(tx, { "amount" => -30_000, "subtransactions" => [ { "amount" => -30_000, "category_id" => @category.public_id } ] }, rebuild_subs: true)
    assert_equal 1, tx.reload.sub_transactions.count
    @history.undo!
    assert_equal base, balances
    assert_equal base_activity, activity
    assert_equal before_ids, tx.reload.sub_transactions.pluck(:id).sort
  end

  test "a reconciled row restores with its status and values" do
    tx = create_tx(amount: 50_000, cleared: "reconciled")
    edit_tx(tx, { "amount" => 51_000 })
    assert_equal "reconciled", tx.reload.cleared
    @history.undo!
    assert_equal 50_000, tx.reload.amount
    assert_equal "reconciled", tx.cleared
  end

  test "a new action after undo drops the redo steps" do
    create_tx
    @history.undo!
    assert @history.can_redo?
    create_tx(amount: -1_000)
    assert_not @history.can_redo?
    assert @history.can_undo?
  end

  test "undo steps back one step at a time in order" do
    a = create_tx(amount: -1_000)
    b = create_tx(amount: -2_000)
    @history.undo!
    assert b.reload.deleted
    assert_not a.reload.deleted
    @history.undo!
    assert a.reload.deleted
  end

  test "a stale row refuses undo and changes nothing" do
    tx = create_tx
    tx.update!(memo: "edited elsewhere")
    base = balances
    steps = UndoStep.count
    error = assert_raises(UndoHistory::Refused) { @history.undo! }
    assert_match(/Nothing was changed/, error.message)
    assert_equal base, balances
    assert_equal steps, UndoStep.count
    assert_equal "edited elsewhere", tx.reload.memo
    assert @history.can_undo?
    assert_not @history.can_redo?
  end

  test "each compared field refuses a stale undo" do
    { "amount" => -99_000, "cleared" => "cleared", "date" => Date.current - 1, "memo" => "x", "approved" => true }.each do |field, value|
      tx = create_tx
      tx.update_columns(field => value)
      assert_raises(UndoHistory::Refused, field) { @history.undo! }
      tx.update_columns(deleted: true)
      @history.steps.delete_all
    end
  end

  test "edit, then reconcile, then undo is refused and the row stays reconciled" do
    tx = create_tx
    edit_tx(tx, { "memo" => "edited" })
    tx.update!(cleared: "reconciled")
    error = assert_raises(UndoHistory::Refused) { @history.undo! }
    assert_match(/edited or reconciled/, error.message)
    assert_equal "reconciled", tx.reload.cleared
    assert_equal "edited", tx.memo
    assert @history.can_undo?
  end

  test "redo refuses when the row changed after the undo" do
    tx = create_tx
    @history.undo!
    tx.update!(memo: "touched while undone")
    assert_raises(UndoHistory::Refused) { @history.redo! }
    assert tx.reload.deleted
    assert @history.can_redo?
  end

  test "a failure between the inverse and the stack move rolls back both" do
    tx = create_tx
    base = balances
    step = @history.steps.first
    UndoStep.class_eval { alias_method :orig_update!, :update! }
    UndoStep.define_method(:update!) { |*| raise ActiveRecord::StatementInvalid, "boom" }
    begin
      assert_raises(ActiveRecord::StatementInvalid) { @history.undo! }
    ensure
      UndoStep.class_eval { alias_method :update!, :orig_update!; remove_method :orig_update! }
    end
    assert_equal base, balances
    assert_not tx.reload.deleted
    assert_not step.reload.undone
    assert @history.can_undo?
  end

  test "a step over the size cap clears both stacks, saves the action and sets the notice" do
    create_tx
    create_tx(amount: -2_000)
    @history.undo!
    assert @history.can_undo? && @history.can_redo?
    big = "m" * (UndoHistory::MAX_STEP_BYTES + 10)
    saved = create_tx(amount: -3_000, extra: { "memo" => big })
    assert saved.reload.persisted?
    assert_not saved.deleted
    assert_not @history.can_undo?
    assert_not @history.can_redo?
    assert_equal UndoHistory::CLEARED, @history.notice
  end

  test "depth is bounded and the oldest step is evicted" do
    (UndoHistory::MAX_STEPS + 3).times { |i| create_tx(amount: -(i + 1) * 100) }
    assert_equal UndoHistory::MAX_STEPS, @history.steps.count
    assert_equal 4, @history.steps.minimum(:position)
  end

  test "history is isolated by token, session, user and plan" do
    create_tx
    assert_not history(token: "other").can_undo?
    assert_not history(session_key: "s2").can_undo?
    other_budget = PlanLifecycle.create_plan(users(:two), name: "Other plan")
    assert_not UndoHistory.new(user: users(:two), budget: other_budget, session_key: "s1", token: "tok").can_undo?
    assert_not UndoHistory.new(user: @user, budget: other_budget, session_key: "s1", token: "tok").can_undo?
  end

  test "undo is refused when the account was removed" do
    tx = create_tx
    delete_tx(tx)
    @account.update!(deleted: true)
    error = assert_raises(UndoHistory::Refused) { @history.undo! }
    assert_match(/account no longer exists/, error.message)
    assert tx.reload.deleted
  end

  test "writes without a history are not recorded" do
    plain = TransactionWriter.new(@budget)
    Transaction.transaction { plain.persist_new!(plain.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -1_000, "payee_name" => "Api")) }
    assert_equal 0, @history.steps.count
  end
end
