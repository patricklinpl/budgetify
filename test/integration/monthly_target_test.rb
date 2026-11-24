require "test_helper"

# Monthly target (#58 TARGET-01, TARGET-04 delete, partial). Refill up to,
# weekly/yearly/custom targets, snoozing and funding modes are U in the audit
# and are not built or asserted here.
class MonthlyTargetTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "target@example.com", password: "password123")
    post session_path, params: { email_address: @user.email_address, password: "password123" }
    @budget = PlanLifecycle.create_plan(@user, name: "Target plan")
    group = @budget.category_groups.create!(name: "Everyday")
    @cat = group.categories.create!(budget: @budget, name: "Groceries")
    @month = Date.current.beginning_of_month
    @path = ->(action) { send("#{action}_users_budget_category_path", @budget.public_id, @cat.public_id) }
  end

  def assigned
    @cat.reload.month_category_for(@month).budgeted.to_i
  end

  test "reference vector: monthly 200 at assigned 125 shows 75 remaining and assigning it gives 200" do
    patch @path.call(:target_update), params: { target: { amount: "200" } }
    assert_redirected_to @path.call(:target)
    MonthAssignment.set!(budget: @budget, category: @cat, month: @month, amount: 125_000, user: @user)
    get @path.call(:target)
    assert_select "p", text: /Target: \$200\.00 every month.*assigned \$125\.00, remaining \$75\.00\./
    assert_select "button", text: "Assign remaining $75.00"
    post @path.call(:target_assign), params: { expected_remaining: 75_000 }
    assert_redirected_to users_budget_path(@budget.public_id)
    assert_equal 200_000, assigned
    assert_equal 1, @budget.money_movements.where(to_category: @cat, amount: 75_000).count
    get @path.call(:target)
    assert_select "p", text: /nothing remaining/
    assert_select "button", text: /Assign remaining/, count: 0
  end

  test "a stale or missing expected amount is refused and nothing changes" do
    patch @path.call(:target_update), params: { target: { amount: "200" } }
    MonthAssignment.set!(budget: @budget, category: @cat, month: @month, amount: 125_000, user: @user)
    post @path.call(:target_assign), params: { expected_remaining: 50_000 }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /remaining amount changed.*Nothing was changed/
    post @path.call(:target_assign), params: {}
    assert_response :unprocessable_entity
    assert_equal 125_000, assigned
  end

  test "invalid, zero and negative amounts are rejected with the typed text kept" do
    [ "abc", "0", "-5", "1.005", "" ].each do |text|
      patch @path.call(:target_update), params: { target: { amount: text } }
      assert_response :unprocessable_entity, text
      assert_select "[role=alert]", text: /Nothing was changed/
    end
    patch @path.call(:target_update), params: { target: { amount: "1.005" } }
    assert_select "input#target_amount[value='1.005']"
    assert_nil @cat.reload.goal_target
  end

  test "a target above the display digits keeps its exact value" do
    patch @path.call(:target_update), params: { target: { amount: "200.25" } }
    assert_equal 200_250, @cat.reload.goal_target
    assert_equal "NEED", @cat.goal_type
    assert_equal 1, @cat.goal_cadence
  end

  test "remove returns to create, keeps assigned, and another kind of target is not replaced" do
    patch @path.call(:target_update), params: { target: { amount: "200" } }
    MonthAssignment.set!(budget: @budget, category: @cat, month: @month, amount: 50_000, user: @user)
    delete @path.call(:target_destroy)
    assert_redirected_to @path.call(:target)
    assert_nil @cat.reload.goal_target
    assert_nil @cat.goal_type
    assert_equal 50_000, assigned
    get @path.call(:target)
    assert_select "p", text: "This category has no target."
    assert_select "button", text: "Create target"

    @cat.update!(goal_type: "TB", goal_target: 300_000)
    patch @path.call(:target_update), params: { target: { amount: "200" } }
    assert_response :unprocessable_entity
    assert_equal 300_000, @cat.reload.goal_target
    get @path.call(:target)
    assert_select "button", text: "Create target", count: 0
    assert_select "button", text: "Remove target"
  end

  test "another user's category and payment categories are not reachable" do
    other = PlanLifecycle.create_plan(User.create!(email_address: "o-target@example.com", password: "password123"), name: "Theirs")
    get target_users_budget_category_path(other.public_id, @cat.public_id)
    assert_response :not_found
    get target_users_budget_category_path(@budget.public_id, "nope")
    assert_response :not_found
  end
end
