require "test_helper"

# Plan screen visual slice 1: the "Overspent" label beside a category name follows
# the same rule as the existing Cover link (negative available AND not a card
# payment category). The Available pill keeps its own accessible label.
# [engineering] The rule is this app's existing Cover rule; it is not a new
# product decision. Synthetic data.
class BudgetGridOverspentLabelTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "overspent-label@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Label plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    @card = Account.open!(budget: @budget, attributes: { "name" => "Visa", "type" => "creditCard", "balance" => 0 })
    @budget.categories.where(internal: false, payment_account_id: nil).update_all(deleted: true)
    @budget.category_groups.where(internal: false).where.not(name: "Credit Card Payments").update_all(deleted: true)
    group = @budget.category_groups.create!(name: "Everyday")
    @over = group.categories.create!(budget: @budget, name: "Overspent fund")
    @ok = group.categories.create!(budget: @budget, name: "Funded fund")
    month = Date.current.beginning_of_month
    MonthAssignment.set!(budget: @budget, category: @ok, month: month, amount: 10_000, user: @user)
    # A negative card payment category: assigned below zero through the same writer.
    @payment = @card.payment_category
    MonthAssignment.set!(budget: @budget, category: @payment, month: month, amount: -5_000, user: @user)
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -4_000,
      "payee_name" => "Shop", "category_id" => @over.public_id, "cleared" => "uncleared"))
  end

  test "only a negative non-payment category gets the Overspent label modifier" do
    get users_budget_path(@budget.public_id)
    assert_response :success
    labelled = css_select("tr.data-table__row .budget-grid__label--overspent").map { |e| e.text.strip }
    assert_equal [ "Overspent fund" ], labelled
    payment_row = css_select("tr.data-table__row").find { |row| row.at_css(".budget-grid__label")&.text&.strip == @payment.name }
    assert payment_row, "the card payment category row is on the plan"
    assert payment_row.at_css("td[data-label=Available] .status-pill--negative"), "the payment category is negative"
    assert_nil payment_row.at_css(".budget-grid__label--overspent")
    assert_nil payment_row.at_css("a.budget-grid__cover")
  end

  test "the negative Available pill carries the accessible Overspent label" do
    get users_budget_path(@budget.public_id)
    over_row = css_select("tr.data-table__row").find { |row| row.at_css(".budget-grid__label")&.text&.strip == "Overspent fund" }
    assert_equal "Overspent", over_row.at_css("td[data-label=Available] .status-pill--negative .data-table__sr").text.strip
    assert_nil over_row.at_css(".budget-grid__label").at_css("[aria-hidden]")
  end
end
