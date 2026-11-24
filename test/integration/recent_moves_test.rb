require "test_helper"

# Recent Moves (#57 MONEY-03): a read-only list of the plan's money movements.
# Tabs and the actor filter were only inspected in the reference (predicates
# unknown), so they are not built or asserted here.
class RecentMovesTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "moves@example.com", password: "password123")
    post session_path, params: { email_address: @user.email_address, password: "password123" }
    @budget = PlanLifecycle.create_plan(@user, name: "Moves plan")
    group = @budget.category_groups.create!(name: "Everyday")
    @a = group.categories.create!(budget: @budget, name: "Alpha")
    @b = group.categories.create!(budget: @budget, name: "Beta")
    @month = Date.current.beginning_of_month
  end

  test "lists assignments, removals and category moves newest first with month, amount and actor" do
    MonthAssignment.set!(budget: @budget, category: @a, month: @month, amount: 150_000, user: @user)
    MonthAssignment.set!(budget: @budget, category: @a, month: @month, amount: 50_000, user: @user)
    @budget.money_movements.create!(month: @month, moved_at: Time.current + 1, performed_by_user: @user, from_category: @a, to_category: @b, amount: 12_345)
    get moves_users_budget_path(@budget.public_id)
    assert_response :success
    rows = css_select("table[aria-label='Recent Moves'] tbody tr").map { |row| row.text.squish }
    assert_equal 3, rows.size
    assert_match(/Moved: Alpha to Beta .*\$12.35 exact 12\.345 moves@example\.com/, rows[0])
    assert_match(/Removed: Alpha .*\$100\.00 moves@example\.com/, rows[1])
    assert_match(/Assigned: Alpha .*\$150\.00 moves@example\.com/, rows[2])
    assert_select "td", text: @month.strftime("%B %Y"), minimum: 3
    get users_budget_path(@budget.public_id)
    assert_select "a.shell-button[href='#{moves_users_budget_path(@budget.public_id)}']", text: "Recent Moves"
  end

  test "an empty plan says so, and another user's plan is not reachable" do
    get moves_users_budget_path(@budget.public_id)
    assert_response :success
    assert_select "p", text: "No money has been moved yet."
    other = PlanLifecycle.create_plan(User.create!(email_address: "o-moves@example.com", password: "password123"), name: "Theirs")
    get moves_users_budget_path(other.public_id)
    assert_response :not_found
  end

  test "deleted movements are not listed" do
    MonthAssignment.set!(budget: @budget, category: @a, month: @month, amount: 5_000, user: @user)
    @budget.money_movements.update_all(deleted: true)
    get moves_users_budget_path(@budget.public_id)
    assert_select "p", text: "No money has been moved yet."
  end
end
