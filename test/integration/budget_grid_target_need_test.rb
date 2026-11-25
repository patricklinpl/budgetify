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
    @zero = group.categories.create!(budget: @budget, name: "Zero fund", goal_type: "NEED", goal_cadence: 1, goal_target: 50_000)
    @neg = group.categories.create!(budget: @budget, name: "Negative fund", goal_type: "NEED", goal_cadence: 1, goal_target: 50_000)
    @fine = group.categories.create!(budget: @budget, name: "Fine fund", goal_type: "NEED", goal_cadence: 1, goal_target: 1_234_567_890)
    @plain = group.categories.create!(budget: @budget, name: "Plain fund")
    @other = group.categories.create!(budget: @budget, name: "Weekly fund", goal_type: "NEED", goal_cadence: 2, goal_target: 50_000)
    month = Date.current.beginning_of_month
    MonthAssignment.set!(budget: @budget, category: @short, month: month, amount: 20_000, user: @user)
    @neg_saved = MonthAssignment.set!(budget: @budget, category: @neg, month: month, amount: -5_000, user: @user)
    MonthAssignment.set!(budget: @budget, category: @fine, month: month, amount: 987_654_321, user: @user)
    MonthAssignment.set!(budget: @budget, category: @met, month: month, amount: 60_000, user: @user)
  end

  def row(name) = css_select("tr.data-table__row").find { |r| r.at_css(".budget-grid__label")&.text&.strip == name }

  test "a monthly target below its amount shows the meter and the remaining amount" do
    get users_budget_path(@budget.public_id)
    meter = row("Short fund").at_css(".budget-grid__meter")
    assert_equal "50000", meter["max"]
    assert_equal "20000", meter["value"]
    assert_equal "$20.00 assigned of $50.00 monthly target", row("Short fund").at_css(".budget-grid__need-text").text.strip
    assert_equal "true", meter["aria-hidden"], "the meter is decorative; the sentence is the accessible content"
    assert_nil meter["aria-valuetext"]
  end

  test "an assigned amount over the target fills the meter and the text keeps the actual amount" do
    get users_budget_path(@budget.public_id)
    meter = row("Met fund").at_css(".budget-grid__meter")
    assert_equal "50000", meter["value"], "value is clamped to the target"
    assert_equal "$60.00 assigned of $50.00 monthly target", row("Met fund").at_css(".budget-grid__need-text").text.strip
  end

  test "categories without the built monthly target show neither" do
    get users_budget_path(@budget.public_id)
    %w[Plain\ fund Weekly\ fund].each do |name|
      assert_nil row(name).at_css(".budget-grid__need"), name
    end
  end

  # goal_needs_whole_amount is true (Set Aside), false (Refill) or nil in the API.
  # The line only states assigned and the target amount, so it is the same for all
  # three and never says funded, underfunded or more needed.
  test "the line is identical for every goal_needs_whole_amount value and claims no funding state" do
    texts = [ nil, true, false ].map do |flag|
      @short.update!(goal_needs_whole_amount: flag)
      get users_budget_path(@budget.public_id)
      line = row("Short fund").at_css(".budget-grid__need-text").text.strip
      assert_no_match(/funded|underfunded|more needed|left to assign/i, line)
      line
    end
    assert_equal [ "$20.00 assigned of $50.00 monthly target" ], texts.uniq
  end

  test "a monthly target with nothing assigned reads zero and the meter is empty" do
    get users_budget_path(@budget.public_id)
    assert_equal "$0.00 assigned of $50.00 monthly target", row("Zero fund").at_css(".budget-grid__need-text").text.strip
    assert_equal "0", row("Zero fund").at_css(".budget-grid__meter")["value"]
  end

  test "a negative Assigned amount is shown as it is and the meter value is clamped to zero" do
    assert_empty @neg_saved.errors.full_messages, "the writer accepted the negative amount"
    get users_budget_path(@budget.public_id)
    assert_equal "-$5.00 assigned of $50.00 monthly target", row("Negative fund").at_css(".budget-grid__need-text").text.strip
    assert_equal "0", row("Negative fund").at_css(".budget-grid__meter")["value"]
  end

  # grid_money prints the exact value next to a rounded one; the sentence keeps that
  # markup as markup (it must never show as literal tag text).
  test "an amount finer than the display digits keeps the exact value and no literal markup" do
    get users_budget_path(@budget.public_id)
    node = row("Fine fund").at_css(".budget-grid__need-text")
    assert_equal "$987,654.32 exact 987654.321 assigned of $1,234,567.89 monthly target", node.text.squish
    assert node.at_css("span.budget-grid__exact"), "the exact value is a real element"
    assert_no_match(/[<>]/, node.text)
  end
end
