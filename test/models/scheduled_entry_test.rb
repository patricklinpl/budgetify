require "test_helper"

# #61 Enter Now at the model level. [reference T] = the audit's persisted
# vectors (SCHED-01, SCHED-BOUNDARY-01/02). [engineering] = refusals, Undo
# atomicity and stale guards the audit does not pin. Fixtures are synthetic.
class ScheduledEntryTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Scheduled plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @category = @plan.categories.not_deleted.where(internal: false, payment_account_id: nil).first
    @history = UndoHistory.new(user: @user, budget: @plan, session_key: "s1", token: "tok")
    @entry = ScheduledEntry.new(@plan, history: @history)
    @today = Date.current
  end

  def schedule(date_next: @today + 30, frequency: "twiceAMonth", amount: -10_000, **extra)
    @plan.scheduled_transactions.create!({ account: @account, date_first: date_next, date_next: date_next, frequency: frequency,
      amount: amount, category: @category, memo: "Rent share" }.merge(extra))
  end

  def balances = @account.reload.then { |a| [ a.cleared_balance, a.uncleared_balance, a.balance ] }

  def counts = [ @plan.transactions.where(deleted: false).count, UndoStep.where(budget: @plan).count ]

  test "a scheduled transaction on its own does not move balances [reference T SCHED-01]" do
    base = balances
    schedule
    assert_equal base, balances
  end

  test "entering creates one uncleared signed transaction dated today and advances the schedule [reference T SCHED-01]" do
    sched = schedule(date_next: Date.new(@today.year + 1, 12, 5))
    base = balances
    transaction = @entry.enter_now!(sched)

    assert_equal 1, @plan.transactions.where(deleted: false).count
    assert_equal [ @today, -10_000, "uncleared", @account.id, @category.id, "Rent share" ],
      [ transaction.date, transaction.amount, transaction.cleared, transaction.account_id, transaction.category_id, transaction.memo ]
    assert_equal Date.new(@today.year + 1, 12, 20), sched.reload.date_next
    assert_equal [ base[0], base[1] - 10_000, base[2] - 10_000 ], balances
  end

  test "a duplicate advances alone and the original keeps its date [reference T SCHED-BOUNDARY-01]" do
    first = Date.new(@today.year + 1, 12, 20)
    original = schedule(date_next: first)
    duplicate = schedule(date_next: first)
    @entry.enter_now!(duplicate)
    assert_equal Date.new(@today.year + 2, 1, 5), duplicate.reload.date_next
    assert_equal first, original.reload.date_next
    assert_equal 1, @plan.transactions.where(deleted: false).count
  end

  test "Feb 15 advances to Feb 28 [reference T SCHED-BOUNDARY-02]" do
    year = @today.year + 2
    year += 1 until !Date.leap?(year)
    sched = schedule(date_next: Date.new(year, 2, 15))
    @entry.enter_now!(sched)
    assert_equal Date.new(year, 2, 28), sched.reload.date_next
  end

  test "one Undo restores the schedule date and removes the transaction; Redo reapplies both [engineering]" do
    first = Date.new(@today.year + 1, 12, 5)
    sched = schedule(date_next: first)
    base = balances
    @entry.enter_now!(sched)
    after = balances

    @history.undo!
    assert_equal first, sched.reload.date_next
    assert_equal 0, @plan.transactions.where(deleted: false).count
    assert_equal base, balances

    @history.redo!
    assert_equal Date.new(@today.year + 1, 12, 20), sched.reload.date_next
    assert_equal 1, @plan.transactions.where(deleted: false).count
    assert_equal after, balances
  end

  test "Undo refuses and changes nothing when any guarded schedule field changed after entry [engineering]" do
    other_account = @plan.accounts.create!(name: "Savings", type: "savings")
    other_category = @plan.categories.not_deleted.where(internal: false, payment_account_id: nil).where.not(id: @category.id).first
    payee = @plan.payees.create!(name: "Landlord")
    { date_next: Date.current + 400, amount: -5_000, memo: "Changed", frequency: "monthly", deleted: true,
      account_id: other_account.id, transfer_account_id: other_account.id, payee_id: payee.id, category_id: other_category.id, flag_color: "red" }.each do |field, value|
      sched = schedule(date_next: Date.new(@today.year + 1, 11, 3))
      @entry.enter_now!(sched)
      sched.update!(field => value)
      state = [ balances, sched.reload.attributes.slice("date_next", "amount"), counts ]
      error = assert_raises(UndoHistory::Refused, "#{field} should make undo stale") { @history.undo! }
      assert_equal UndoHistory::STALE, error.message
      assert_equal state, [ balances, sched.reload.attributes.slice("date_next", "amount"), counts ]
      UndoStep.where(budget: @plan).delete_all
      @plan.scheduled_transactions.delete_all
      @plan.transactions.update_all(deleted: true)
      @account.update_columns(cleared_balance: 0, uncleared_balance: 0, balance: 0)
    end
  end

  test "eligibility is judged on the locked row, not on a copy loaded before a concurrent change [engineering]" do
    { deleted: true, frequency: "monthly", transfer_account_id: @plan.accounts.create!(name: "Savings", type: "savings").id,
      date_next: @today }.each do |field, value|
      sched = schedule
      stale_copy = ScheduledTransaction.find(sched.id)
      ScheduledTransaction.where(id: sched.id).update_all(field => value)
      state = [ balances, counts ]
      assert_raises(ScheduledEntry::Unsupported, "#{field} changed after load must be refused") { @entry.enter_now!(stale_copy) }
      assert_equal state, [ balances, counts ]
      assert_equal value, ScheduledTransaction.find(sched.id)[field]
    end

    split = schedule
    stale_copy = ScheduledTransaction.find(split.id)
    split.scheduled_sub_transactions.create!(amount: -10_000)
    assert_raises(ScheduledEntry::Unsupported) { @entry.enter_now!(stale_copy) }
    assert_equal 0, @plan.transactions.where(deleted: false).count
  end

  test "Undo refuses when the entered transaction was deleted afterwards [engineering]" do
    sched = schedule
    transaction = @entry.enter_now!(sched)
    Transaction.transaction { TransactionWriter.new(@plan).destroy!(transaction) }
    date = sched.reload.date_next
    assert_raises(UndoHistory::Refused) { @history.undo! }
    assert_equal date, sched.reload.date_next
  end

  test "a failure after the transaction is saved rolls back everything and reloads the schedule [engineering]" do
    first = Date.current + 30
    sched = schedule(date_next: first)
    base = balances
    counts_before = counts
    failing = Object.new
    failing.define_singleton_method(:record!) { |**| raise "forced failure after persist" }

    assert_raises(RuntimeError) { ScheduledEntry.new(@plan, history: failing).enter_now!(sched) }
    assert_equal counts_before, counts
    assert_equal base, balances
    assert_equal first, sched.date_next, "the in-memory schedule is reloaded"
    assert_equal first, sched.reload.date_next
  end

  test "unsupported schedules raise before any write [engineering]" do
    other_plan = PlanLifecycle.create_plan(users(:two), name: "Other plan")
    other_account = other_plan.accounts.create!(name: "Other", type: "checking")
    savings = @plan.accounts.create!(name: "Savings", type: "savings")
    cases = {
      "other frequency" => schedule(frequency: "monthly"),
      "never" => schedule(frequency: "never"),
      "due today" => schedule(date_next: @today),
      "past due" => schedule(date_next: @today - 3),
      "transfer" => schedule(transfer_account: savings),
      "deleted" => schedule(deleted: true),
      "other plan" => other_plan.scheduled_transactions.create!(account: other_account, date_first: @today + 9, date_next: @today + 9, frequency: "twiceAMonth", amount: -1_000)
    }
    split = schedule
    split.scheduled_sub_transactions.create!(amount: -10_000)
    cases["split"] = split

    cases.each do |label, sched|
      before = [ counts, balances, sched.reload.date_next ]
      assert_raises(ScheduledEntry::Unsupported, label) { @entry.enter_now!(sched) }
      assert_equal before, [ counts, balances, sched.reload.date_next ], label
    end
  end

  test "history steps without a schedule section still undo as before [engineering]" do
    writer = TransactionWriter.new(@plan, history: @history)
    Transaction.transaction { writer.persist_new!(writer.build({ "account_id" => @account.public_id, "date" => @today.iso8601, "amount" => -1_000, "cleared" => "uncleared" })) }
    @history.undo!
    assert_equal 0, @plan.transactions.where(deleted: false).count
  end
end
