require "test_helper"

# Confirm step of the CSV import: what it writes, the one Undo step, and the
# refusals. [reference] Matching keeps the manual date, payee, memo and category
# (YNAB Approving and Matching help). [engineering] New rows uncleared,
# unapproved, uncategorized; the hidden bank counterpart; Undo clears import ids.
# Synthetic data.
class ImportConfirmTest < ActionDispatch::IntegrationTest
  TURBO = { "X-Turbo-Request-Id" => "t" }.freeze
  CSV = "Date,Payee,Memo,Outflow,Inflow\n2026-10-15,Bank Cafe,card,4.50,\n2026-10-16,Pay,Salary,,100.00\n2026-10-15,Old,,9.00,\n".freeze

  setup do
    @user = User.create!(email_address: "confirm@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Confirm plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    @category = @budget.categories.not_deleted.where(internal: false).first
    @cafe_payee = @budget.payees.create!(name: "My Cafe")
    @manual = TransactionWriter.new(@budget).persist_new!(TransactionWriter.new(@budget).build(
      "account_id" => @account.public_id, "date" => "2026-10-12", "amount" => -4_500, "payee_id" => @cafe_payee.public_id,
      "category_id" => @category.public_id, "memo" => "mine", "cleared" => "cleared"))
    @budget.transactions.create!(account: @account, date: Date.new(2026, 10, 15), amount: -9_000, import_id: "CSV:-9000:2026-10-15:1")
    @account.reload
  end

  def preview(text = CSV, **params)
    file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "bank.csv")
    post users_budget_account_import_preview_path(@budget.public_id, @account.public_id), params: { file: file, date_format: "iso" }.merge(params), headers: TURBO
  end

  def confirm_form
    assert_select "form.import-confirm"
    { draft: css_select("form.import-confirm input[name=draft]").first["value"], digest: css_select("form.import-confirm input[name=digest]").first["value"] }
  end

  def confirm(params = nil)
    post users_budget_account_import_confirm_path(@budget.public_id, @account.public_id), params: params || confirm_form, headers: TURBO
  end

  def live = @budget.transactions.not_deleted.where(account: @account)
  def state = [ live.count, live.sum(:amount), @account.reload.balance, @account.cleared_balance, @account.uncleared_balance ]

  test "preview offers a confirm button only when something would be written" do
    preview
    assert_select "form.import-confirm button", text: "Import 2 transactions"
    preview("Date,Payee,Memo,Outflow,Inflow\n2026-10-15,Old,,9.00,\n")
    assert_select "form.import-confirm", false
  end

  test "confirm adds new rows uncleared, unapproved and uncategorized, and links the match" do
    preview
    before_balance = @account.reload.balance
    assert_difference -> { live.count }, 1 do
      assert_difference -> { ImportDraft.count }, -1 do
        confirm
      end
    end
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    new_tx = live.find_by(import_id: "CSV:100000:2026-10-16:1")
    assert_equal [ "uncleared", false, nil, 100_000 ], [ new_tx.cleared, new_tx.approved, new_tx.category_id, new_tx.amount ]
    assert_equal "Pay", new_tx.payee.name
    assert_equal "Salary", new_tx.memo
    assert_equal before_balance + 100_000, @account.reload.balance
    @manual.reload
    assert_equal [ "cleared", @category.id, @cafe_payee.id, "mine", Date.new(2026, 10, 12), true ], [ @manual.cleared, @manual.category_id, @manual.payee_id, @manual.memo, @manual.date, @manual.approved ]
    bank = @manual.matched_transaction
    assert bank.deleted
    assert_equal "CSV:-4500:2026-10-15:1", bank.import_id
    assert_equal bank.id, @manual.matched_transaction_id
    assert_equal @manual.id, bank.matched_transaction_id
    assert_equal 1, live.where(amount: -4_500).count, "the match must not add a second -4.50"
  end

  test "the whole import is one Undo step, and Redo restores it" do
    preview(CSV + "2026-10-17,Third,,1.00,\n")
    original = state
    confirm
    imported = state
    assert_equal 2, imported[0] - original[0]
    assert_equal 1, UndoStep.where(kind: "import").count
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal original, state
    assert_nil @manual.reload.matched_transaction_id
    assert_equal 0, @budget.transactions.where(deleted: false).where.not(import_id: nil).where("import_id LIKE 'CSV:100000%' OR import_id LIKE 'CSV:-1000%'").count
    post users_budget_redo_path(@budget.public_id), headers: TURBO
    assert_equal imported, state
    assert_equal @manual.id, @manual.reload.matched_transaction.matched_transaction_id
  end

  test "importing the same file again after an Undo brings the rows back; without an Undo it skips them" do
    preview
    confirm
    preview
    assert_select "form.import-confirm", false, "second import of the same file has nothing to write"
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    preview
    assert_select "form.import-confirm button", text: "Import 2 transactions"
  end

  test "a changed account since the preview is refused and writes nothing" do
    preview
    form = confirm_form
    @budget.transactions.create!(account: @account, date: Date.new(2026, 10, 16), amount: 100_000, import_id: "CSV:100000:2026-10-16:1")
    before = state
    confirm(form)
    assert_redirected_to users_budget_account_transactions_path(@budget.public_id, @account.public_id)
    assert_match(/no longer matches/, flash[:alert])
    assert_equal before, state
    assert_equal 0, UndoStep.where(kind: "import").count
  end

  test "a wrong digest is refused and a repeated confirm finds nothing" do
    preview
    form = confirm_form
    before = state
    confirm(form.merge(digest: "0" * 64))
    assert_match(/no longer matches/, flash[:alert])
    assert_equal before, state
    confirm(form)
    assert_equal before[0] + 1, state[0]
    confirm(form)
    assert_match(/already confirmed or has expired/, flash[:alert])
    assert_equal before[0] + 1, state[0]
  end

  test "a row that cannot be written rolls the whole import back" do
    future = (Date.current + 5).iso8601
    preview("Date,Payee,Memo,Outflow,Inflow\n2026-10-16,Pay,,,100.00\n#{future},Later,,1.00,\n")
    before = state
    payees = @budget.payees.count
    confirm
    assert_match(/Line 3: .*future.* Nothing was imported/, flash[:alert])
    assert_equal before, state
    assert_equal payees, @budget.payees.count
    assert_equal 0, UndoStep.where(kind: "import").count
  end

  test "a reconciled transaction is never matched" do
    @manual.update!(cleared: "reconciled")
    preview
    assert_select "tr[data-status=matched]", false
    assert_select "tr[data-status=new]", 2
  end

  test "another user's draft, a closed account and a foreign plan are refused" do
    preview
    form = confirm_form
    other = User.create!(email_address: "other@example.com", password: "password123")
    sign_in_as(other)
    post users_budget_account_import_confirm_path(@budget.public_id, @account.public_id), params: form, headers: TURBO
    assert_response :not_found
    sign_in_as(@user)
    @account.update!(closed: true)
    before = state
    confirm(form)
    assert_match(/closed/, flash[:alert])
    assert_equal before, state
  end

  test "imports larger than an ordinary Undo step still record one step" do
    rows = (1..150).map { |i| "2026-09-#{format('%02d', (i % 28) + 1)},Shop #{i},,#{i}.00," }.join("\n")
    preview("Date,Payee,Memo,Outflow,Inflow\n#{rows}\n")
    confirm
    assert_equal 150, live.where.not(import_id: nil).count - 1
    assert_equal 1, UndoStep.where(kind: "import").count
    post users_budget_undo_path(@budget.public_id), headers: TURBO
    assert_equal 1, live.where.not(import_id: nil).count
  end

  test "two submits of the same form write once, even when both loaded the draft first" do
    preview
    form = confirm_form
    first = ImportDraft.find_by!(token: form[:draft])
    second = ImportDraft.find_by!(token: form[:draft])
    history = UndoHistory.new(user: @user, budget: @budget, session_key: "s", token: "t")
    build = ->(draft) { CsvImportCommit.new(budget: @budget, account: @account, draft: draft, user: @user, history: history, digest: form[:digest]) }
    before = live.count
    build.call(first).call
    assert_equal before + 1, live.count
    error = assert_raises(CsvImportCommit::Refused) { build.call(second).call }
    assert_equal CsvImportCommit::ALREADY, error.message
    assert_equal before + 1, live.count
    assert_equal 1, UndoStep.where(kind: "import").count
  end

  test "a draft is only usable on its own user, plan and account" do
    preview
    form = confirm_form
    before = state
    other_account = Account.open!(budget: @budget, attributes: { "name" => "Savings", "type" => "savings", "balance" => 0 })
    post users_budget_account_import_confirm_path(@budget.public_id, other_account.public_id), params: form, headers: TURBO
    assert_equal CsvImportCommit::ALREADY, flash[:alert]
    assert_equal 0, @budget.transactions.where(account: other_account).where.not(import_id: nil).count
    other = User.create!(email_address: "second@example.com", password: "password123")
    other_budget = PlanLifecycle.create_plan(other, name: "Other plan")
    other_budget_account = Account.open!(budget: other_budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    sign_in_as(other)
    post users_budget_account_import_confirm_path(other_budget.public_id, other_budget_account.public_id), params: form, headers: TURBO
    assert_equal CsvImportCommit::ALREADY, flash[:alert]
    assert_equal 0, other_budget.transactions.where.not(import_id: nil).count
    assert_equal 1, ImportDraft.count, "the draft is untouched by every refused attempt"
    sign_in_as(@user)
    assert_equal before, state
  end
end
