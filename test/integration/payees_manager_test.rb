require "test_helper"

# #65 payees manager, rename only. [reference] PAYEE-01: renaming a payee keeps the
# new name when reopened. [engineering] An explicit Save form per row, the
# duplicate-name rule (case-insensitive within the plan, case-only rename of the
# same payee allowed), transfer payees excluded, a rejected rename writes nothing,
# plan and user isolation. Combine, hide and unhide are not built. Synthetic data.
class PayeesManagerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "payees@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Payee plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 50_000 })
    @savings = Account.open!(budget: @budget, attributes: { "name" => "Savings", "type" => "savings", "balance" => 0 })
    @cafe = @budget.payees.create!(name: "Corner Cafe")
    @grocer = @budget.payees.create!(name: "Fresh Grocer")
    writer = TransactionWriter.new(@budget)
    writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -4_000,
      "payee_id" => @cafe.public_id, "cleared" => "uncleared"))
  end

  def names = css_select(".payee-list__row input[name='payee[name]']").map { |input| input["value"] } - [ "Starting Balance" ]

  test "lists the plan's payees without transfer payees" do
    get users_budget_payees_path(@budget.public_id)
    assert_response :success
    assert_equal [ "Corner Cafe", "Fresh Grocer" ], names
    assert_select ".payee-list__row button", text: "Save", count: 3
    assert_no_match(/Savings|Checking/, css_select(".payee-list__row input").map { |i| i["value"] }.join(" "))
  end

  test "renaming saves, keeps the transaction on the same payee and survives a reload" do
    patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "  Harbour Cafe  " } }
    assert_redirected_to users_budget_payees_path(@budget.public_id)
    follow_redirect!
    assert_select "p[role=status]", text: "Payee renamed to Harbour Cafe."
    get users_budget_payees_path(@budget.public_id)
    assert_equal [ "Fresh Grocer", "Harbour Cafe" ], names
    transaction = @budget.transactions.find_by!(payee_id: @cafe.id)
    assert_equal "Harbour Cafe", transaction.payee.name
    assert_equal @cafe.id, @cafe.reload.id
  end

  test "a rename advances the plan knowledge counter" do
    assert_difference -> { @budget.reload.server_knowledge }, 1 do
      patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "Harbour Cafe" } }
    end
  end

  test "an empty name is rejected, the typed text is kept and nothing is written" do
    patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "   " } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Name can.t be blank/
    assert_equal "Corner Cafe", @cafe.reload.name
  end

  test "a duplicate name is rejected case-insensitively with the typed text kept" do
    patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "fresh grocer" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /already been taken/
    assert_includes names, "fresh grocer"
    assert_equal "Corner Cafe", @cafe.reload.name
  end

  test "a case-only rename of the same payee is allowed" do
    patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "corner cafe" } }
    assert_redirected_to users_budget_payees_path(@budget.public_id)
    assert_equal "corner cafe", @cafe.reload.name
  end

  test "a name over the length limit is rejected" do
    patch users_budget_payee_path(@budget.public_id, @cafe.public_id), params: { payee: { name: "x" * 501 } }
    assert_response :unprocessable_entity
    assert_equal "Corner Cafe", @cafe.reload.name
  end

  test "a transfer payee cannot be edited here" do
    transfer = @budget.payees.find_by!(transfer_account_id: @savings.id)
    patch users_budget_payee_path(@budget.public_id, transfer.public_id), params: { payee: { name: "Renamed" } }
    assert_response :not_found
    assert_not_equal "Renamed", transfer.reload.name
  end

  test "another user's plan and payees stay out of reach" do
    other = User.create!(email_address: "other-payees@example.com", password: "password123")
    plan = PlanLifecycle.create_plan(other, name: "Theirs")
    theirs = plan.payees.create!(name: "Theirs Only")
    get users_budget_payees_path(plan.public_id)
    assert_response :not_found
    patch users_budget_payee_path(@budget.public_id, theirs.public_id), params: { payee: { name: "Stolen" } }
    assert_response :not_found
    assert_equal "Theirs Only", theirs.reload.name
  end

  test "the plan settings page links to the manager" do
    get settings_users_budget_path(@budget.public_id)
    assert_select "a[href=?]", users_budget_payees_path(@budget.public_id), text: "Manage payees"
  end
end
