require "test_helper"

# Reset Available Amount (#58 AUTO-RESET-01). Fixtures are synthetic.
# [reference] = the audit's T vector; [engineering] = refusals for U cases.
class ResetAvailableTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "reset@example.com", password: "password123")
    @budget = PlanLifecycle.create_plan(@user, name: "Reset plan")
    group = @budget.category_groups.create!(name: "Everyday")
    @dining = group.categories.create!(budget: @budget, name: "Dining")
    @month = Date.current.beginning_of_month
    @account = @budget.accounts.create!(name: "Checking", type: "checking", balance: 0)
    # +10 activity on the category (a refund-style inflow), assigned 0.
    @budget.transactions.create!(account: @account, date: @month, amount: 10_000, category: @dining).apply_amounts!(1)
  end

  test "[reference] AUTO-RESET-01 vector: 0/+10/10 becomes -10/+10/0 and Ready to Assign rises 10" do
    assert_equal [ 0, 10_000, 10_000 ], figures
    rta = rta_now
    assert_equal 10_000, reset(10_000)
    assert_equal [ -10_000, 10_000, 0 ], figures
    assert_equal rta + 10_000, rta_now
  end

  test "[reference] it is an assignment ledger row, not a transaction" do
    tx = @budget.transactions.count
    balance = @account.reload.balance
    reset(10_000)
    assert_equal tx, @budget.transactions.count
    assert_equal balance, @account.reload.balance
    movement = @budget.money_movements.order(:id).last
    assert_equal [ @dining.id, nil, 10_000 ], [ movement.from_category_id, movement.to_category_id, movement.amount ]
  end

  test "[engineering] assigned money is reset too: assigned 5 / activity 0 / available 5 -> assigned 0" do
    MonthAssignment.set!(budget: @budget, category: @dining, month: @month, amount: 5_000, user: @user)
    assert_equal [ 5_000, 10_000, 15_000 ], figures
    reset(15_000)
    assert_equal [ -10_000, 10_000, 0 ], figures
  end

  test "[engineering] zero or negative available is refused and nothing changes" do
    reset(10_000)
    before = [ figures, @budget.money_movements.count ]
    assert_raises(ResetAvailable::Refused) { reset(0) }
    @budget.transactions.create!(account: @account, date: @month, amount: -4_000, category: @dining).apply_amounts!(1)
    negative = ResetAvailable.available(@dining, @month)
    assert_operator negative, :<, 0
    assert_raises(ResetAvailable::Refused) { reset(negative) }
    assert_equal before[1], @budget.money_movements.count
    assert_equal before[0].first, MonthCategory.find_by(category: @dining, month: @month).budgeted
  end

  test "[engineering] a stale expected amount is refused and nothing changes" do
    before = [ figures, @budget.money_movements.count ]
    assert_raises(ResetAvailable::Refused) { reset(9_999) }
    assert_raises(ResetAvailable::Refused) { reset("10000") }
    assert_equal before, [ figures, @budget.money_movements.count ]
  end

  test "[engineering] other months, hidden, internal, payment and foreign categories are refused" do
    assert_raises(ResetAvailable::Refused) { ResetAvailable.reset!(budget: @budget, category: @dining, month: @month.next_month, user: @user, expected_available: 10_000) }
    @dining.update!(hidden: true)
    assert_raises(ResetAvailable::Refused) { reset(10_000) }
    @dining.update!(hidden: false)
    card = @budget.accounts.create!(name: "Visa", type: "creditCard", balance: 0)
    payment = @budget.categories.not_deleted.find_by!(payment_account_id: card.id)
    inflow = @budget.categories.find_by!(internal: true, name: Budget::INFLOW_CATEGORY_NAME)
    other = PlanLifecycle.create_plan(User.create!(email_address: "o-reset@example.com", password: "password123"), name: "Foreign")
    foreign = other.category_groups.create!(name: "G").categories.create!(budget: other, name: "Theirs")
    foreign_tx_account = other.accounts.create!(name: "Theirs", type: "checking", balance: 0)
    other.transactions.create!(account: foreign_tx_account, date: @month, amount: 3_000, category: foreign).apply_amounts!(1)
    assert inflow.hidden, "premise: the Ready to Assign category is hidden, so internal is the only independent rule if hidden is cleared"
    inflow.update_column(:hidden, false)
    gone = @budget.category_groups.first.categories.create!(budget: @budget, name: "Gone")
    @budget.transactions.create!(account: @account, date: @month, amount: 2_000, category: gone).apply_amounts!(1)
    gone.update_column(:deleted, true)
    [ [ payment, @budget ], [ inflow, @budget ], [ foreign, @budget ], [ gone, @budget ] ].each do |category, plan|
      MonthAssignment.set!(budget: category.budget, category: category, month: @month, amount: 5_000, user: @user) unless category == foreign
      positive = ResetAvailable.available(category, @month)
      assert_operator positive, :>, 0, "#{category.name} must have a positive available so only the category rule can refuse it"
      assert_raises(ResetAvailable::Refused) { ResetAvailable.reset!(budget: plan, category: category, month: @month, user: @user, expected_available: positive) }
    end
    assert_equal [ 0, 10_000, 10_000 ], figures
  end

  private
    def reset(expected)
      ResetAvailable.reset!(budget: @budget, category: @dining, month: @month, user: @user, expected_available: expected)
    end

    def figures
      data = CategorySerializer.as_json(@dining.reload, month: @month)
      [ data[:budgeted], data[:activity], data[:balance] ]
    end

    def rta_now
      MonthSerializer.summary_as_json(@budget, @month)[:to_be_budgeted]
    end
end
