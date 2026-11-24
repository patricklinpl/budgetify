require "test_helper"

# Reconcile (#63 REC-01 to REC-03), whole-dollar audit numbers. The audit gives
# no adjustment memo text; the memo here is Budgetify's own wording and stays an
# unverified item. REC-04/05 (reconciled edit warnings, Undo) are not built.
class ReconciliationTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "rec@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Rec plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
    @writer = TransactionWriter.new(@budget)
  end

  def add(amount, cleared, subs: nil, payee: "Shop")
    attrs = { "account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => amount, "payee_name" => payee, "cleared" => cleared }
    attrs["subtransactions"] = subs if subs
    @writer.persist_new!(@writer.build(attrs))
  end

  def balances = @account.reload.then { |a| [ a.cleared_balance, a.uncleared_balance, a.balance ] }
  def path = users_budget_account_reconciliation_path(@budget.public_id, @account.public_id)
  def register = users_budget_account_transactions_path(@budget.public_id, @account.public_id)

  def seed_rec01
    add(1_000_000, "cleared")
    add(-10_000, "uncleared")
  end

  test "REC-01 asks for the cleared balance, not the working balance" do
    seed_rec01
    assert_equal [ 1_000_000, -10_000, 990_000 ], balances
    get path
    assert_response :success
    assert_select "h2", text: /Is your account balance \$1000\.00\?/
  end

  test "REC-01 yes marks cleared rows reconciled, leaves uncleared and balances, and hides reconciled by default" do
    seed_rec01
    post path, params: { answer: "yes" }
    assert_redirected_to register
    assert_equal [ 1_000_000, -10_000, 990_000 ], balances
    assert_equal %w[reconciled], @account.transactions.where(amount: 1_000_000).pluck(:cleared)
    assert_equal %w[uncleared], @account.transactions.where(amount: -10_000).pluck(:cleared)
    assert_equal 0, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count

    get register
    assert_select "td[data-label=Status]", text: "Uncleared"
    assert_select "td[data-label=Status]", text: "Reconciled", count: 0
    assert_select ".register-page__hidden", text: /1 reconciled transaction hidden/
    get register, params: { reconciled: "1" }
    assert_select "td[data-label=Status]", text: "Reconciled"
    assert_select "a", text: "Hide Reconciled"
    assert_equal [ 1_000_000, -10_000, 990_000 ], balances
  end

  test "REC-02 no with 945 shows difference -5 and one adjustment finishes" do
    add(950_000, "cleared")
    add(-10_000, "uncleared")
    post path, params: { answer: "no", step: "review", balance: "945" }
    assert_response :success
    assert_select "dd", text: "-$5.00"
    assert_select "button", text: "Create Adjustment & Finish"
    assert_select "p", text: /recorded as reconciled in Ready to Assign\./
    assert_equal [ 950_000, -10_000, 940_000 ], balances

    rta = -> { MonthSerializer.summary_as_json(@budget, Date.current.beginning_of_month).fetch(:to_be_budgeted) }
    rta_before = rta.call
    post path, params: { answer: "no", step: "finish", balance: "945" }
    assert_redirected_to register
    assert_equal rta_before - 5_000, rta.call, "the outflow adjustment lowers Ready to Assign by 5"
    assert_equal [ 945_000, -10_000, 935_000 ], balances
    adjustment = @account.transactions.find_by!(memo: Account::RECONCILIATION_MEMO)
    assert_equal(-5_000, adjustment.amount)
    assert_equal "reconciled", adjustment.cleared
    assert_equal Date.current, adjustment.date
    assert_equal "Reconciliation Balance Adjustment", adjustment.payee.name
    assert_equal Budget::INFLOW_CATEGORY_NAME, adjustment.category.name
    assert_equal 1, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
  end

  test "REC-03 two split parents reconcile, the uncleared row does not, and the difference counts once" do
    2.times do
      add(-50_000, "cleared", subs: [ { "amount" => -25_000 }, { "amount" => -25_000 } ])
    end
    add(-10_000, "uncleared")
    before = balances
    post path, params: { answer: "yes" }
    assert_equal before, balances
    assert_equal 2, @account.transactions.where(cleared: "reconciled").count
    assert_equal 1, @account.transactions.where(cleared: "uncleared").count
    assert_equal 0, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
  end

  test "invalid entered balance keeps the text, changes nothing and shows an error" do
    seed_rec01
    post path, params: { answer: "no", step: "review", balance: "12.345" }
    assert_response :unprocessable_entity
    assert_select "input[name=balance][value='12.345']"
    assert_select "p", text: "Nothing was changed."
    assert_equal %w[cleared uncleared], @account.transactions.order(:cleared).pluck(:cleared)
    post path, params: { answer: "no", step: "review", balance: "" }
    assert_response :unprocessable_entity
  end

  test "a tracking account adjustment has no category and leaves Ready to Assign alone" do
    tracking = @budget.accounts.create!(name: "Asset", type: "otherAsset", on_budget: false)
    @account = tracking
    add(950_000, "cleared")
    rta = -> { MonthSerializer.summary_as_json(@budget, Date.current.beginning_of_month).fetch(:to_be_budgeted) }
    before = rta.call
    post path, params: { answer: "no", step: "finish", balance: "945" }
    assert_nil tracking.transactions.find_by!(memo: Account::RECONCILIATION_MEMO).category
    assert_equal before, rta.call
  end

  test "a credit card debt adjustment has no category and leaves Ready to Assign alone" do
    @account = @budget.accounts.create!(name: "Card", type: "creditCard")
    add(-95_000, "cleared")
    rta = -> { MonthSerializer.summary_as_json(@budget, Date.current.beginning_of_month).fetch(:to_be_budgeted) }
    before = rta.call
    post path, params: { answer: "no", step: "finish", balance: "-96" }
    adjustment = @account.transactions.find_by!(memo: Account::RECONCILIATION_MEMO)
    assert_equal(-1_000, adjustment.amount)
    assert_nil adjustment.category
    assert_equal before, rta.call
  end

  test "a repeated finish writes no second adjustment" do
    add(950_000, "cleared")
    2.times { post path, params: { answer: "no", step: "finish", balance: "945" } }
    assert_equal 1, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
    assert_equal [ 945_000, 0, 945_000 ], balances
  end

  test "a stale account instance reconciles against the current rows and balances" do
    add(950_000, "cleared")
    stale = Account.find(@account.id)
    add(20_000, "cleared") # changes the balances after the instance was loaded
    add(-10_000, "uncleared")
    stale.reconcile!(entered: 955_000)
    assert_equal [ 955_000, -10_000, 945_000 ], balances
    adjustment = @account.transactions.find_by!(memo: Account::RECONCILIATION_MEMO)
    assert_equal(-15_000, adjustment.amount)
    assert_equal 2, @account.transactions.where(cleared: "reconciled").where.not(id: adjustment.id).count
    assert_equal 1, @account.transactions.where(cleared: "uncleared").count
  end

  test "a credit card adjustment that would reach or start from a positive balance is refused with no write" do
    @account = @budget.accounts.create!(name: "Card", type: "creditCard")
    add(-95_000, "cleared")
    post path, params: { answer: "no", step: "finish", balance: "5" }
    assert_response :unprocessable_entity
    assert_select "p", text: /not supported yet/
    assert_equal 0, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
    assert_equal "cleared", @account.transactions.first.cleared
    assert_equal [ -95_000, 0, -95_000 ], balances
    post path, params: { answer: "yes" }
    assert_redirected_to register
  end

  test "a card with cleared debt and an uncleared inflow (working balance positive) is refused with no write" do
    @account = @budget.accounts.create!(name: "Card", type: "creditCard")
    add(-5_000, "cleared")
    add(20_000, "uncleared")
    assert_equal [ -5_000, 20_000, 15_000 ], balances
    post path, params: { answer: "no", step: "finish", balance: "6" }
    assert_response :unprocessable_entity
    assert_equal 0, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
    assert_equal [ -5_000, 20_000, 15_000 ], balances
  end

  test "matching entered balance needs no adjustment" do
    seed_rec01
    post path, params: { answer: "no", step: "finish", balance: "1000" }
    assert_redirected_to register
    assert_equal 0, @account.transactions.where(memo: Account::RECONCILIATION_MEMO).count
    assert_equal "reconciled", @account.transactions.find_by(amount: 1_000_000).cleared
  end

  test "a closed account refuses with no write" do
    seed_rec01
    @account.update_columns(closed: true)
    post path, params: { answer: "yes" }
    assert_response :unprocessable_entity
    assert_equal "cleared", @account.transactions.find_by(amount: 1_000_000).cleared
  end

  test "another user's plan is a 404" do
    other = User.create!(email_address: "rec2@example.com", password: "password123")
    other_budget = PlanLifecycle.create_plan(other, name: "Other")
    other_account = other_budget.accounts.create!(name: "Mine", type: "checking")
    get users_budget_account_reconciliation_path(other_budget.public_id, other_account.public_id)
    assert_response :not_found
  end
end
