require "test_helper"

# Plan screen: a category with the built monthly target shows a thin progress
# meter and "more needed" text under its name, from Assigned and the target.
# [engineering] Only the existing monthly target is shown (MonthlyTarget.monthly?).
# No new target semantics, no change to the Available pill. Synthetic data.
class BudgetGridTargetNeedTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "target-need@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Need plan")
    @budget.categories.where(internal: false, payment_account_id: nil).update_all(deleted: true)
    @budget.category_groups.where(internal: false).where.not(name: "Credit Card Payments").update_all(deleted: true)
    group = @budget.category_groups.create!(name: "Everyday")
    @short = group.categories.create!(budget: @budget, name: "Short fund", goal_type: "NEED", goal_cadence: 1, goal_target: 50_000)
    @met = group.categories.create!(budget: @budget, name: "Met fund", goal_type: "NEED", goal_cadence: 1, goal_target: 50_000)
    @plain = group.categories.create!(budget: @budget, name: "Plain fund")
    @other = group.categories.create!(budget: @budget, name: "Weekly fund", goal_type: "NEED", goal_cadence: 2, goal_target: 50_000)
    month = Date.current.beginning_of_month
    MonthAssignment.set!(budget: @budget, category: @short, month: month, amount: 20_000, user: @user)
    MonthAssignment.set!(budget: @budget, category: @met, month: month, amount: 60_000, user: @user)
  end

  def row(name) = css_select("tr.data-table__row").find { |r| r.at_css(".budget-grid__label")&.text&.strip == name }

  test "a monthly target below its amount shows the meter and the remaining amount" do
    get users_budget_path(@budget.public_id)
    meter = row("Short fund").at_css(".budget-grid__meter")
    assert_equal "50000", meter["max"]
    assert_equal "20000", meter["value"]
    assert_equal "$30.00 more needed", row("Short fund").at_css(".budget-grid__need-text").text.strip
    assert_equal MonthlyTarget.remaining(@short, Date.current.beginning_of_month), 30_000
  end

  test "an assigned amount at or above the target fills the meter and shows no more-needed text" do
    get users_budget_path(@budget.public_id)
    meter = row("Met fund").at_css(".budget-grid__meter")
    assert_equal "50000", meter["value"], "value is clamped to the target"
    assert_nil row("Met fund").at_css(".budget-grid__need-text")
  end

  test "categories without the built monthly target show neither" do
    get users_budget_path(@budget.public_id)
    %w[Plain\ fund Weekly\ fund].each do |name|
      assert_nil row(name).at_css(".budget-grid__need"), name
    end
  end
end
