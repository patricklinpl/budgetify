require "test_helper"

# The CSV import preview page: it shows every row with its result and reason, the
# detected columns and the problems, and it writes nothing.
# [reference] Dialog options and matching rules come from YNAB's File-Based Import
# help page, not observed in the reference app. [engineering] The page layout, the
# wording and the settings form are this app's own. Synthetic data.
class ImportPreviewTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "preview@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Preview plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 0 })
    @day = Date.new(2026, 10, 15)
    @budget.transactions.create!(account: @account, date: @day, amount: -4_500, cleared: "uncleared")
    @budget.transactions.create!(account: @account, date: @day, amount: -9_000, cleared: "uncleared", import_id: "CSV:-9000:2026-10-15:1")
  end

  def upload(text, **params)
    file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "bank.csv")
    post users_budget_account_import_preview_path(@budget.public_id, @account.public_id), params: { file: file, date_format: "iso" }.merge(params)
  end

  def counts = [ @budget.transactions.count, @budget.transactions.sum(:amount), @account.reload.balance ]

  test "every row shows its result and the reason, and nothing is written" do
    before = counts
    upload("Date,Payee,Memo,Outflow,Inflow\n2026-10-15,Cafe,,4.50,\n2026-10-15,Shop,,9.00,\n2026-10-16,Pay,Salary,,100.00\n")
    assert_response :success
    assert_equal before, counts
    assert_select ".dialog__survives", text: /Nothing was imported/
    assert_select "tr[data-status=matched]", text: /Matches a transaction you entered: same amount, 0 day/
    assert_select "tr[data-status=skipped]", text: /Already imported: same date and amount/
    assert_select "tr[data-status=new]", text: /No matching transaction/
    assert_select ".import-preview__counts", text: /1 new, 1 matched to a transaction you entered, 1 skipped, 0 with problems/
    assert_select ".import-preview__mapping dd", text: "Column 1 (Date)"
  end

  test "problems are listed with their line and the good rows still show" do
    upload("Date,Payee,Memo,Outflow,Inflow\n2026-10-17,Ok,,1.00,\n2026-10-18,Bad,,\"12,34\",\n")
    assert_response :success
    assert_select ".plan-settings__errors p", text: "Line 3: Outflow is not a plain number"
    assert_select "tr[data-status=new]", 1
  end

  test "the comma amount format reads 12,34 as 12.34" do
    upload("Date,Payee,Memo,Outflow,Inflow\n2026-10-17,Cafe,,\"12,34\",\n", amount_format: "comma")
    assert_select "tr[data-status=new] td.money", text: "-$12.34"
    assert_select ".plan-settings__errors", false
  end

  test "the date format and the swap setting are applied" do
    upload("Date,Payee,Memo,Outflow,Inflow\n10/17/2026,Cafe,,5.00,\n", date_format: "us", swap: "1")
    assert_select "tr td", text: "2026-10-17"
    assert_select "tr[data-status=new] td.money", text: "$5.00"
  end

  test "no file, or an empty file, is refused with a message" do
    post users_budget_account_import_preview_path(@budget.public_id, @account.public_id), params: { date_format: "iso" }
    assert_response :unprocessable_entity
    assert_select ".plan-settings__errors", text: /Choose a CSV file/
    upload("")
    assert_response :unprocessable_entity
  end

  test "a file param that is not an upload is refused with 422, not a 500" do
    [ "just text", [ "a", "b" ], { "x" => "y" } ].each do |value|
      post users_budget_account_import_preview_path(@budget.public_id, @account.public_id), params: { file: value, date_format: "iso" }
      assert_response :unprocessable_entity
      assert_select ".plan-settings__errors", text: /Choose a CSV file/
    end
  end

  test "markup in a payee or memo is escaped" do
    upload("Date,Payee,Memo,Outflow,Inflow\n2026-10-17,<script>alert(1)</script>,<b>bold</b>,1.00,\n")
    assert_response :success
    assert_no_match(/<script>alert/, response.body)
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_select "td b", false
  end

  test "amounts in the preview have thousands separators" do
    upload("Date,Payee,Memo,Outflow,Inflow\n2026-10-17,Big,,\"1,234.50\",\n")
    assert_select "td.money", text: "-$1,234.50"
  end

  test "a file over the row cap is refused with a message and lists no rows" do
    rows = Array.new(CsvImport::MAX_ROWS + 1) { |i| "2026-10-17,P#{i},,1.00," }.join("\n")
    upload("Date,Payee,Memo,Outflow,Inflow\n#{rows}\n")
    assert_response :success
    assert_select ".plan-settings__errors", text: /more than 5000 rows/
    assert_select "tr[data-status]", false
  end

  test "an unreadable file is reported on the page, not raised" do
    upload("Date,Payee,Outflow,Inflow\n2026-10-15,Caf\xE9,4.50,\n".b)
    assert_response :success
    assert_select ".plan-settings__errors", text: /not valid UTF-8/
  end

  test "another user's plan is a 404" do
    other = User.create!(email_address: "other-preview@example.com", password: "password123")
    plan = PlanLifecycle.create_plan(other, name: "Theirs")
    account = Account.open!(budget: plan, attributes: { "name" => "Theirs", "type" => "checking", "balance" => 0 })
    post users_budget_account_import_preview_path(plan.public_id, account.public_id), params: { date_format: "iso" }
    assert_response :not_found
  end

  test "sign in is required" do
    delete users_session_path rescue nil
    reset!
    post users_budget_account_import_preview_path(@budget.public_id, @account.public_id), params: { date_format: "iso" }
    assert_response :redirect
  end
end
