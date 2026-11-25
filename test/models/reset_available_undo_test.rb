require "test_helper"

# Undo and Redo of Reset Available Amount (#58 AUTO-RESET-01 Undo part).
# [reference T] = the audit vector: Undo restores 0 / +10 / +10 and Ready to
# Assign 0. [engineering] = guards, ledger shape and rollback. Synthetic data.
class ResetAvailableUndoTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "reset-undo@example.com", password: "password123")
    @budget = PlanLifecycle.create_plan(@user, name: "Reset undo plan")
    group = @budget.category_groups.create!(name: "Everyday")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    @month = Date.current.beginning_of_month
    @account = @budget.accounts.create!(name: "Checking", type: "checking", balance: 0)
    @budget.transactions.create!(account: @account, date: @month, amount: 10_000, category: @dining).apply_amounts!(1)
    @history = UndoHistory.new(user: @user, budget: @budget, session_key: "s1", token: "tok")
  end

  test "[reference] Undo restores 0 / +10 / +10 and Ready to Assign 0" do
    rta = rta_now
    reset
    assert_equal [ -10_000, 10_000, 0 ], figures
    assert_equal rta + 10_000, rta_now

    @history.undo!
    assert_equal [ 0, 10_000, 10_000 ], figures
    assert_equal rta, rta_now
  end

  test "[engineering] Redo repeats the reset (the audit pins Undo only)" do
    rta = rta_now
    reset
    @history.undo!
    @history.redo!
    assert_equal [ -10_000, 10_000, 0 ], figures
    assert_equal rta + 10_000, rta_now
  end

  test "[engineering] the ledger is append-only and no transaction or balance changes" do
    transactions = @budget.transactions.count
    balance = @account.reload.balance
    reset
    first = @budget.money_movements.order(:id).last.attributes
    @history.undo!
    assert_equal first, @budget.money_movements.find(first["id"]).attributes
    reverse = @budget.money_movements.order(:id).last
    assert_equal [ nil, @dining.id, 10_000 ], [ reverse.from_category_id, reverse.to_category_id, reverse.amount ]
    assert_equal 2, @budget.money_movements.where(month: @month).count
    assert_equal transactions, @budget.transactions.count
    assert_equal balance, @account.reload.balance
    assert_equal 10_000, figures[1]
  end

  test "[engineering] without a history nothing is recorded" do
    ResetAvailable.reset!(budget: @budget, category: @dining, month: @month, user: @user, expected_available: 10_000)
    assert_not @history.can_undo?
  end

  {
    assigned: -> { MonthAssignment.set!(budget: @budget, category: @dining, month: @month, amount: -9_000, user: @user) },
    activity: -> { @budget.transactions.create!(account: @account, date: @month, amount: -1_000, category: @dining).apply_amounts!(1) },
    carry_forward_available: -> { MonthAssignment.set!(budget: @budget, category: @dining, month: @month.prev_month, amount: 4_000, user: @user) }
  }.each do |name, drift|
    test "[engineering] Undo refuses and changes nothing when #{name} drifted" do
      reset
      pre = figures
      instance_exec(&drift)
      post = figures
      case name
      when :assigned then assert_not_equal pre[0], post[0]
      when :activity then assert_not_equal pre[1], post[1]
      when :carry_forward_available
        assert_equal [ pre[0], pre[1] ], [ post[0], post[1] ], "precondition: only available changed"
        assert_not_equal pre[2], post[2]
      end
      movements = @budget.money_movements.count
      error = assert_raises(UndoHistory::Refused) { @history.undo! }
      assert_equal UndoHistory::STALE, error.message
      assert_equal post, figures
      assert_equal movements, @budget.money_movements.count
      assert @history.can_undo?
    end
  end

  test "[engineering] Undo refuses when only activity drifted: assigned and available are held fixed by a compensating prior-month assignment" do
    reset
    pre = figures
    @budget.transactions.create!(account: @account, date: @month, amount: -1_000, category: @dining).apply_amounts!(1)
    MonthAssignment.set!(budget: @budget, category: @dining, month: @month.prev_month, amount: 1_000, user: @user)
    post = figures
    assert_equal [ pre[0], pre[2] ], [ post[0], post[2] ], "precondition: assigned and available unchanged"
    assert_not_equal pre[1], post[1], "precondition: activity changed"
    movements = @budget.money_movements.count
    assert_raises(UndoHistory::Refused) { @history.undo! }
    assert_equal post, figures
    assert_equal movements, @budget.money_movements.count
    assert @history.can_undo?
  end

  { hidden: true, deleted: true, internal: true, payment_account_id: :account }.each do |field, value|
    test "[engineering] Undo refuses when the category became ineligible: #{field}" do
      reset
      @dining.update_column(field, value == :account ? @account.id : value)
      movements = @budget.money_movements.count
      assert_raises(UndoHistory::Refused) { @history.undo! }
      assert_equal movements, @budget.money_movements.count
      assert @history.can_undo?
    end
  end

  test "[engineering] Undo refuses after the month rolls over" do
    reset
    travel_to(@month.next_month + 2.days) do
      assert_raises(UndoHistory::Refused) { @history.undo! }
    end
    assert_equal [ -10_000, 10_000, 0 ], figures
  end

  test "[engineering] Redo guards the before image: drift after Undo refuses Redo" do
    reset
    @history.undo!
    @budget.transactions.create!(account: @account, date: @month, amount: -1_000, category: @dining).apply_amounts!(1)
    state = figures
    assert_raises(UndoHistory::Refused) { @history.redo! }
    assert_equal state, figures
    assert @history.can_redo?
  end

  test "[engineering] a failure after assigned is written rolls everything back" do
    reset
    movements = @budget.money_movements.count
    with_failing_movement { assert_raises(RuntimeError) { @history.undo! } }
    assert_equal [ -10_000, 10_000, 0 ], figures
    assert_equal movements, @budget.money_movements.count
    assert @history.can_undo?
    assert_not @history.can_redo?
  end

  test "[engineering] a reset step sits in one stack with transaction steps" do
    writer = TransactionWriter.new(@budget, history: @history)
    Transaction.transaction do
      writer.persist_new!(writer.build({ "account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -2_000,
        "payee_name" => "Shop", "cleared" => "uncleared", "category_id" => @dining.public_id }))
    end
    reset(8_000)
    assert_equal [ -8_000, 8_000, 0 ], figures
    @history.undo!
    assert_equal [ 0, 8_000, 8_000 ], figures
    @history.undo!
    assert_equal [ 0, 10_000, 10_000 ], figures
  end

  private
    def reset(expected = 10_000)
      ResetAvailable.reset!(budget: @budget, category: @dining, month: @month, user: @user, expected_available: expected, history: @history)
    end

    # assigned is already saved when the ledger write fails: a mid-block failure.
    def with_failing_movement
      original = MonthAssignment.method(:record_movement)
      MonthAssignment.define_singleton_method(:record_movement) { |*| raise "boom" }
      yield
    ensure
      MonthAssignment.define_singleton_method(:record_movement, original)
    end

    def figures
      data = CategorySerializer.as_json(@dining.reload, month: @month)
      [ data[:budgeted], data[:activity], data[:balance] ]
    end

    def rta_now = MonthSerializer.summary_as_json(@budget, @month)[:to_be_budgeted]
end
