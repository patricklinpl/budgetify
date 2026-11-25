require "test_helper"

# Undo slice 1 through the browser paths: buttons, endpoints, page-load token,
# isolation, refusals and the notices.
class UndoControlsTest < ActionDispatch::IntegrationTest
  TURBO = { "X-Turbo-Request-Id" => "t1" }.freeze

  setup do
    @user = users(:one)
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Undo UI plan")
    @account = @budget.accounts.create!(name: "Checking", type: "checking")
  end

  def register_path = users_budget_account_transactions_path(@budget.public_id, @account.public_id)
  def undo_button(disabled:) = assert_select("form[action='#{users_budget_undo_path(@budget.public_id)}'] button#{disabled ? '[disabled]' : ':not([disabled])'}", text: "Undo")
  def redo_button(disabled:) = assert_select("form[action='#{users_budget_redo_path(@budget.public_id)}'] button#{disabled ? '[disabled]' : ':not([disabled])'}", text: "Redo")

  def add_tx(memo: "one", outflow: "10")
    post users_budget_account_transactions_path(@budget.public_id, @account.public_id),
      params: { transaction: { date: Date.current.iso8601, payee: "Shop", category_id: "", memo: memo, outflow: outflow, inflow: "" } }, headers: TURBO
  end

  test "first load has Undo and Redo disabled" do
    get register_path
    undo_button(disabled: true)
    redo_button(disabled: true)
  end

  test "adding a transaction enables Undo, Undo removes it and enables Redo, a new action drops Redo" do
    get register_path
    add_tx
    get register_path, headers: TURBO
    undo_button(disabled: false)
    redo_button(disabled: true)
    assert_equal(-10_000, @account.reload.balance)

    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_redirected_to users_budget_path(@budget.public_id)
    assert_equal 0, @account.reload.balance
    get register_path, headers: TURBO
    undo_button(disabled: true)
    redo_button(disabled: false)
    assert_select "p.shell-undo-status", text: /Undid adding the transaction/

    add_tx(memo: "two")
    get register_path, headers: TURBO
    redo_button(disabled: true)
    undo_button(disabled: false)
  end

  test "redo puts the transaction back" do
    get register_path
    add_tx
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    post users_budget_redo_path(@budget.public_id), headers: TURBO
    assert_equal(-10_000, @account.reload.balance)
  end

  test "a reload (a request that is not a Turbo visit) disables both buttons" do
    get register_path
    add_tx
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    get register_path, headers: TURBO
    redo_button(disabled: false)

    get register_path
    undo_button(disabled: true)
    redo_button(disabled: true)
    assert_equal 0, UndoStep.count
  end

  test "sign-out removes the history" do
    get register_path
    add_tx
    assert_equal 1, UndoStep.count
    delete session_path
    assert_equal 0, UndoStep.count
  end

  test "edit and delete from the register are undoable" do
    get register_path
    add_tx
    tx = @budget.transactions.last
    path = users_budget_account_transaction_path(@budget.public_id, @account.public_id, tx.public_id)
    patch path, params: { transaction: { date: Date.current.iso8601, payee: "Shop", category_id: "", memo: "edited", outflow: "25", inflow: "" } }, headers: TURBO
    assert_equal(-25_000, tx.reload.amount)
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal(-10_000, tx.reload.amount)
    delete path, headers: TURBO
    assert tx.reload.deleted
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_not tx.reload.deleted
    assert_equal(-10_000, @account.reload.balance)
  end

  test "a stale step is refused with a stated message and nothing changes" do
    get register_path
    add_tx
    tx = @budget.transactions.last
    tx.update!(memo: "changed elsewhere")
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    follow_redirect!
    assert_select "p.shell-undo-status", text: /Nothing was changed/
    assert_equal(-10_000, @account.reload.balance)
    assert_not tx.reload.deleted
  end

  test "another user and another plan cannot undo this history" do
    get register_path
    add_tx
    other_budget = PlanLifecycle.create_plan(users(:two), name: "Other")
    post users_budget_undo_path(other_budget.public_id), headers: TURBO
    assert_response :not_found
    assert_equal(-10_000, @account.reload.balance)
  end

  test "undo without a step says so and changes nothing" do
    get register_path
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    follow_redirect!
    assert_select "p.shell-undo-status", text: /nothing to undo/i
  end

  test "an over-size action clears history and announces it" do
    get register_path
    add_tx
    add_tx(memo: "m" * (UndoHistory::MAX_STEP_BYTES + 10))
    follow_redirect!
    assert_select "p.shell-undo-status", text: /Undo history was cleared/
    get register_path, headers: TURBO
    undo_button(disabled: true)
    assert_equal 2, @budget.transactions.count
  end

  test "saving a split from the split editor is recorded and Undo restores the original children" do
    category = @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).first
    writer = TransactionWriter.new(@budget)
    tx = writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -30_000,
      "payee_name" => "Store", "subtransactions" => [ { "amount" => -10_000, "category_id" => category.public_id }, { "amount" => -20_000, "category_id" => category.public_id } ]))
    original = tx.sub_transactions.pluck(:id).sort
    get register_path
    patch users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, tx.public_id), headers: TURBO, params: { split: {
      outflow: "30", inflow: "", rows: { "0" => { category_id: category.public_id, memo: "a", outflow: "30", inflow: "" } } } }
    assert_redirected_to register_path
    assert_equal 1, tx.reload.sub_transactions.count
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal original, tx.reload.sub_transactions.pluck(:id).sort
    assert_equal(-30_000, @account.reload.balance)
  end

  # Real browser path for the split editor: its form is not a Turbo form, so
  # neither the PATCH nor the redirect GET carries X-Turbo-Request-Id.
  def seeded_split
    category = @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).first
    writer = TransactionWriter.new(@budget)
    tx = writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601, "amount" => -30_000,
      "payee_name" => "Store", "subtransactions" => [ { "amount" => -10_000, "category_id" => category.public_id }, { "amount" => -20_000, "category_id" => category.public_id } ]))
    [ tx, category ]
  end

  def plain_split_patch(tx, category, total: "30")
    patch users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, tx.public_id), params: { split: {
      outflow: total, inflow: "", rows: { "0" => { category_id: category.public_id, memo: "a", outflow: total, inflow: "" } } } }
  end

  test "a split save from the non-Turbo form keeps its step across the plain redirect, and Undo works" do
    tx, category = seeded_split
    original = tx.sub_transactions.pluck(:id).sort
    get register_path
    plain_split_patch(tx, category)
    assert_redirected_to register_path
    follow_redirect!
    undo_button(disabled: false)
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal original, tx.reload.sub_transactions.pluck(:id).sort
  end

  test "reloading or replaying the register after a non-Turbo split save still clears history" do
    tx, category = seeded_split
    get register_path
    plain_split_patch(tx, category)
    follow_redirect!
    undo_button(disabled: false)
    get register_path
    undo_button(disabled: true)
  end

  test "the keep marker is for the exact redirect path only: another full page load clears history" do
    tx, category = seeded_split
    get register_path
    plain_split_patch(tx, category)
    get users_budget_path(@budget.public_id)
    undo_button(disabled: true)
  end

  test "a refused or re-rendered non-Turbo split save sets no keep marker and nothing is recorded" do
    tx, category = seeded_split
    get register_path
    patch users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, tx.public_id), params: { split: {
      outflow: "99", inflow: "", rows: { "0" => { category_id: category.public_id, memo: "a", outflow: "30", inflow: "" } } } }
    assert_response :unprocessable_entity
    assert_equal 0, UndoStep.count
    get register_path
    undo_button(disabled: true)
  end

  test "a non-Turbo reconciliation post is not recorded and its redirect clears existing history" do
    add_tx
    get register_path, headers: TURBO
    undo_button(disabled: false)
    steps_before = UndoStep.count
    post users_budget_account_reconciliation_path(@budget.public_id, @account.public_id), params: { answer: "yes" }
    assert_response :redirect
    assert_equal steps_before, UndoStep.count, "reconciliation records no step"
    follow_redirect!
    undo_button(disabled: true)
  end

  test "a document load purges steps older than a day from any session and keeps recent ones" do
    make = ->(session_key, age) { UndoStep.create!(user: @user, budget: @budget, session_key: session_key, token: "t", position: 1, kind: "create", before_json: "{}", after_json: "{}", byte_size: 4, created_at: age) }
    old = make.call("other-session", 2.days.ago)
    recent = make.call("another-session", 1.hour.ago)
    get register_path, headers: TURBO
    assert UndoStep.exists?(old.id), "a Turbo visit does not purge"
    get register_path
    assert_not UndoStep.exists?(old.id)
    assert UndoStep.exists?(recent.id)
  end
end
