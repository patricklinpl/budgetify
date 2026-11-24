require "test_helper"

# Cover Overspending (#57 MONEY-04): full deficit coverage only. Fixtures are
# synthetic. Partial coverage, payment categories and other months are
# untested in the reference (U) and are refused, not guessed.
class CoverOverspendingTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "cover@example.com", password: "password123")
    post session_path, params: { email_address: @user.email_address, password: "password123" }
    @budget = PlanLifecycle.create_plan(@user, name: "Cover plan")
    group = @budget.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @budget, name: "Groceries")
    @source = group.categories.create!(budget: @budget, name: "Rainy day")
    @month = Date.current.beginning_of_month
    account = @budget.accounts.create!(name: "Checking", type: "checking", balance: 1_000_000)
    @budget.transactions.create!(account: account, date: @month, amount: -43_210, category: @groceries).apply_amounts!(1)
    MonthAssignment.set!(budget: @budget, category: @source, month: @month, amount: 100_000, user: @user)
  end

  test "reference vector: deficit moves from the source, totals and accounts unchanged" do
    assert_equal [ 0, -43_210, -43_210 ], figures(@groceries)
    assert_equal [ 100_000, 0, 100_000 ], figures(@source)
    rta = rta_now
    balance = @budget.accounts.find_by!(name: "Checking").balance

    get cover_users_budget_category_path(@budget.public_id, @groceries.public_id)
    assert_response :success
    assert_select "option", text: /Rainy day/
    post cover_users_budget_category_path(@budget.public_id, @groceries.public_id), params: { source_id: @source.public_id }
    assert_redirected_to users_budget_path(@budget.public_id)

    assert_equal [ 43_210, -43_210, 0 ], figures(@groceries)
    assert_equal [ 56_790, 0, 56_790 ], figures(@source)
    assert_equal rta, rta_now
    assert_equal balance, @budget.accounts.find_by!(name: "Checking").reload.balance
    movement = @budget.money_movements.order(:id).last
    assert_equal [ @source.id, @groceries.id, 43_210 ], [ movement.from_category_id, movement.to_category_id, movement.amount ]
  end

  test "a source with less available than the whole deficit is refused and nothing changes" do
    MonthAssignment.set!(budget: @budget, category: @source, month: @month, amount: 10_000, user: @user)
    before = [ figures(@groceries), figures(@source), @budget.money_movements.count ]
    post cover_users_budget_category_path(@budget.public_id, @groceries.public_id), params: { source_id: @source.public_id }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Nothing was changed/
    assert_equal before, [ figures(@groceries), figures(@source), @budget.money_movements.count ]
  end

  test "covering from itself, an unknown source or a non-overspent category is refused" do
    [ @groceries.public_id, "nope" ].each do |id|
      post cover_users_budget_category_path(@budget.public_id, @groceries.public_id), params: { source_id: id }
      assert_response :unprocessable_entity
    end
    post cover_users_budget_category_path(@budget.public_id, @source.public_id), params: { source_id: @groceries.public_id }
    assert_response :unprocessable_entity
    assert_equal [ 0, -43_210, -43_210 ], figures(@groceries)
  end

  test "payment categories and another user's plan are not reachable" do
    other = User.create!(email_address: "other-cover@example.com", password: "password123")
    foreign = PlanLifecycle.create_plan(other, name: "Foreign")
    foreign_category = foreign.category_groups.create!(name: "G").categories.create!(budget: foreign, name: "Theirs")
    post cover_users_budget_category_path(@budget.public_id, @groceries.public_id), params: { source_id: foreign_category.public_id }
    assert_response :unprocessable_entity
    get cover_users_budget_category_path(foreign.public_id, foreign_category.public_id)
    assert_response :not_found
  end

  test "a credit card payment category is refused as a source" do
    card = @budget.accounts.create!(name: "Visa", type: "creditCard", balance: 0)
    payment = @budget.categories.not_deleted.find_by!(payment_account_id: card.id)
    post cover_users_budget_category_path(@budget.public_id, @groceries.public_id), params: { source_id: payment.public_id }
    assert_response :unprocessable_entity
    assert_equal [ 0, -43_210, -43_210 ], figures(@groceries)
  end

  test "the grid links overspent categories to the cover page" do
    get users_budget_path(@budget.public_id)
    assert_select "a[aria-label='Cover overspending for Groceries']"
    assert_select "a[aria-label='Cover overspending for Rainy day']", count: 0
  end

  private
    def figures(category)
      data = CategorySerializer.as_json(category.reload, month: @month)
      [ data[:budgeted], data[:activity], data[:balance] ]
    end

    def rta_now
      MonthSerializer.summary_as_json(@budget, @month)[:to_be_budgeted]
    end
end
