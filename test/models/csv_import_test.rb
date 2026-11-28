require "test_helper"

# CSV import planning: parsing and duplicate matching only, nothing is written.
# [reference] Columns Date, Payee, Memo, Outflow, Inflow, the options, the
# ten-day match on exact amounts, and skipping exact date and amount repeats come
# from YNAB's File-Based Import help page; they were not observed in the
# reference app. [engineering] Everything else (header names, date format
# choice, import id, nearest match) is this app's own choice. Synthetic data.
class CsvImportTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Import plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @day = Date.new(2026, 10, 15)
  end

  def plan(text, **options)
    CsvImport.plan(text, account: @account, date_format: :iso, **options)
  end

  def enter!(amount, date, **extra)
    @plan.transactions.create!({ account: @account, date: date, amount: amount, cleared: "uncleared" }.merge(extra))
  end

  test "[reference] columns map to Date, Payee, Memo, Outflow and Inflow by header name" do
    result = plan("Date,Payee,Memo,Outflow,Inflow\n2026-10-15,Cafe,Latte,4.50,\n2026-10-16,Employer,Pay,,100.00\n")
    assert_equal [ [ @day, "Cafe", "Latte", -4_500 ], [ @day + 1, "Employer", "Pay", 100_000 ] ], result.rows.map { |r| [ r.date, r.payee, r.memo, r.amount ] }
    assert_empty result.problems
    assert_equal({ new: 2 }, result.counts)
  end

  test "[reference] no header row reads the columns in the documented order" do
    result = plan("2026-10-15,Cafe,Latte,4.50,\n", no_header: true)
    assert_equal [ -4_500 ], result.rows.map(&:amount)
    assert_equal [ 1 ], result.rows.map(&:line)
  end

  test "[reference] swap inflow and outflow flips every sign" do
    result = plan("Date,Payee,Memo,Outflow,Inflow\n2026-10-15,Cafe,,4.50,\n", swap: true)
    assert_equal [ 4_500 ], result.rows.map(&:amount)
  end

  test "[engineering] bank style header names, quotes, thousands separators and CRLF" do
    text = "Transaction Date,Description,Debit,Credit\r\n2026-10-15,\"Cafe, Main St\",\"$1,234.50\",\r\n"
    result = plan(text)
    assert_equal [ [ "Cafe, Main St", -1_234_500 ] ], result.rows.map { |r| [ r.payee, r.amount ] }
  end

  test "[engineering] the date format is explicit, and a row that does not fit it is reported, not guessed" do
    text = "Date,Payee,Outflow,Inflow\n10/15/2026,Cafe,4.50,\n2026-10-15,Other,1.00,\n"
    iso = plan(text)
    assert_equal [ "Other" ], iso.rows.map(&:payee)
    assert_equal [ 2 ], iso.problems.map(&:line)
    us = CsvImport.plan(text, account: @account, date_format: :us)
    assert_equal [ @day ], us.rows.map(&:date)
    assert_equal [ 3 ], us.problems.map(&:line)
    assert_raises(ArgumentError) { CsvImport.plan(text, account: @account, date_format: :guess) }
  end

  test "[engineering] an amount that is not a plain number is a problem on its line" do
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,abc,\n2026-10-16,Shop,1.0005,\n2026-10-17,Ok,2.00,\n")
    assert_equal [ 2, 3 ], result.problems.map(&:line)
    assert_equal [ -2_000 ], result.rows.map(&:amount)
  end

  test "[engineering] a file with no date column or no amount column plans nothing" do
    assert_match(/date/, plan("Payee,Outflow\nCafe,1.00\n").problems.first.message)
    assert_match(/amount/, plan("Date,Payee\n2026-10-15,Cafe\n").problems.first.message)
  end

  test "[reference] an exact amount within ten days matches a manual entry, eleven days does not" do
    near = enter!(-4_500, @day + 10)
    far = enter!(-7_000, @day + 11)
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n2026-10-15,Shop,7.00,\n")
    assert_equal %i[matched new], result.rows.map(&:status)
    assert_equal near, result.rows.first.matched_transaction
    assert_nil result.rows.last.matched_transaction
    assert far.persisted?
  end

  test "[reference] a different amount never matches, even on the same day" do
    enter!(-4_501, @day)
    assert_equal %i[new], plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n").rows.map(&:status)
  end

  test "[engineering] the nearest manual entry wins and each one matches a single row" do
    far = enter!(-4_500, @day + 6)
    near = enter!(-4_500, @day + 2)
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,A,4.50,\n2026-10-15,B,4.50,\n2026-10-15,C,4.50,\n")
    assert_equal %i[matched matched new], result.rows.map(&:status)
    assert_equal [ near, far ], result.rows.first(2).map(&:matched_transaction)
  end

  test "[reference] a row with the same date and amount as one already imported is skipped" do
    enter!(-4_500, @day, import_id: "CSV:-4500:2026-10-15:1")
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n2026-10-15,Cafe again,4.50,\n")
    assert_equal %i[skipped new], result.rows.map(&:status)
  end

  test "[reference] a row that was imported and then deleted is skipped too" do
    enter!(-4_500, @day, import_id: "CSV:-4500:2026-10-15:1", deleted: true)
    assert_equal %i[skipped], plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n").rows.map(&:status)
  end

  test "[engineering] a manual entry on the same day and amount is a match, not a skip" do
    manual = enter!(-4_500, @day)
    row = plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n").rows.first
    assert_equal :matched, row.status
    assert_equal manual, row.matched_transaction
  end

  test "[engineering] repeated rows in the file get their own import ids" do
    ids = plan("Date,Payee,Outflow,Inflow\n2026-10-15,A,4.50,\n2026-10-15,B,4.50,\n").rows.map(&:import_id)
    assert_equal [ "CSV:-4500:2026-10-15:1", "CSV:-4500:2026-10-15:2" ], ids
  end

  test "[reference] rows before the account start date can be left out" do
    @account.update_columns(balance: 0)
    enter!(0, @day, opening_balance: true, cleared: "cleared")
    text = "Date,Payee,Outflow,Inflow\n2026-10-01,Old,1.00,\n2026-10-20,New,2.00,\n"
    assert_equal [ true, false ], plan(text).rows.map(&:before_start)
    assert_equal [ @day + 5 ], plan(text, include_before_start: false).rows.map(&:date)
  end

  test "[engineering] planning writes nothing" do
    enter!(-4_500, @day)
    before = [ @plan.transactions.count, @plan.transactions.sum(:amount), @plan.transactions.where.not(matched_transaction_id: nil).count ]
    plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n")
    assert_equal before, [ @plan.transactions.count, @plan.transactions.sum(:amount), @plan.transactions.where.not(matched_transaction_id: nil).count ]
  end

  def amounts(outflow, inflow = "")
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,Cafe,#{outflow},#{inflow}\n")
    [ result.rows.map(&:amount), result.problems.map(&:message) ]
  end

  test "[engineering] a comma is a thousands separator only in groups of three digits" do
    assert_equal [ [ -1_234_000 ], [] ], amounts("\"1,234\"")
    assert_equal [ [ -12_345_600 ], [] ], amounts("\"12,345.60\"")
    assert_equal [ [], [ "Outflow is not a plain number" ] ], amounts("\"12,34\"")
    assert_equal [ [], [ "Outflow is not a plain number" ] ], amounts("\"1,23\"")
    assert_equal [ [], [ "Outflow is not a plain number" ] ], amounts("\"1,2345\"")
    assert_equal [ [ 1_234_500 ], [] ], amounts("", "\"$1,234.50\"")
  end

  test "[engineering] a negative or parenthesised amount is reported, never turned into the opposite sign" do
    assert_equal [ [], [ "Outflow is negative, which is not read" ] ], amounts("-4.50")
    assert_equal [ [], [ "Inflow is negative, which is not read" ] ], amounts("", "-4.50")
    assert_equal [ [], [ "Outflow is in parentheses, which is not read" ] ], amounts("(4.50)")
    assert_equal [ [], [ "Outflow is negative, which is not read" ] ], amounts("-$4.50")
    assert_equal [ [ -4_500 ], [] ], amounts("+4.50")
  end

  test "[engineering] both cells blank, or both with an amount, is reported" do
    assert_equal [ [], [ "No amount in the Outflow or Inflow cell" ] ], amounts("", "")
    assert_equal [ [], [ "Both Outflow and Inflow have an amount" ] ], amounts("4.50", "4.50")
    assert_equal [ [ -4_500 ], [] ], amounts("4.50", "0.00")
    assert_equal [ [ 0 ], [] ], amounts("0.00", "")
  end

  test "[engineering] an unterminated quote is reported and nothing after it is read" do
    result = plan("Date,Payee,Outflow,Inflow\n2026-10-15,\"Cafe,4.50,\n2026-10-16,Shop,1.00,\n")
    assert_empty result.rows
    assert_match(/never closed/, result.problems.first.message)
  end

  test "[engineering] invalid UTF-8 and oversized text are reported, not raised" do
    bad = "Date,Payee,Outflow,Inflow\n2026-10-15,Caf\xE9,4.50,\n".b
    result = plan(bad)
    assert_empty result.rows
    assert_match(/not valid UTF-8/, result.problems.first.message)
    assert_equal 1, plan("Date,Payee,Outflow,Inflow\n2026-10-15,Caf\u00E9,4.50,\n".b).rows.size
    big = "x" * (CsvImport::MAX_BYTES + 1)
    assert_match(/larger than/, plan(big).problems.first.message)
  end

  test "[engineering] a byte order mark at the start of the file is ignored" do
    assert_equal [ -4_500 ], plan("\uFEFFDate,Payee,Outflow,Inflow\n2026-10-15,Cafe,4.50,\n").rows.map(&:amount)
  end

  test "[engineering] a two-digit year is reported, not read as year 26" do
    us = CsvImport.plan("Date,Payee,Outflow,Inflow\n10/15/26,Cafe,4.50,\n10/15/2026,Ok,1.00,\n", account: @account, date_format: :us)
    assert_equal [ @day ], us.rows.map(&:date)
    assert_equal [ 2 ], us.problems.map(&:line)
    iso = plan("Date,Payee,Outflow,Inflow\n26-10-15,Cafe,4.50,\n")
    assert_empty iso.rows
    assert_equal 1, iso.problems.size
  end

  test "[engineering] the comma amount format reads a decimal comma and a point thousands separator" do
    text = "Date,Payee,Outflow,Inflow\n2026-10-15,A,\"12,34\",\n2026-10-15,B,\"1.234,50\",\n2026-10-15,C,\"1,234\",\n"
    result = CsvImport.plan(text, account: @account, date_format: :iso, amount_format: :comma)
    assert_equal [ -12_340, -1_234_500, -1_234 ], result.rows.map(&:amount)
    assert_empty result.problems
    assert_raises(ArgumentError) { CsvImport.plan(text, account: @account, date_format: :iso, amount_format: :other) }
  end

  test "[engineering] the row cap is enforced at the limit" do
    ok = Array.new(CsvImport::MAX_ROWS) { "2026-10-17,P,,1.00," }.join("\n")
    assert_equal CsvImport::MAX_ROWS, plan("Date,Payee,Memo,Outflow,Inflow\n#{ok}\n").rows.size
    over = plan("Date,Payee,Memo,Outflow,Inflow\n#{ok}\n2026-10-17,P,,1.00,\n")
    assert_empty over.rows
    assert_match(/more than 5000 rows/, over.problems.first.message)
  end

  test "[engineering] every row has a reason" do
    enter!(-4_500, @day)
    enter!(-9_000, @day, import_id: "CSV:-9000:2026-10-15:1")
    rows = plan("Date,Payee,Outflow,Inflow\n2026-10-15,A,4.50,\n2026-10-15,B,9.00,\n2026-10-15,C,1.00,\n").rows
    assert_equal [ :matched, :skipped, :new ], rows.map(&:status)
    assert rows.all? { |r| r.reason.present? }
  end

  test "[engineering] quotes: a doubled quote, a comma and a line break inside quotes, and a quote at the end of the file" do
    text = "Date,Payee,Memo,Outflow,Inflow\r\n2026-10-15,\"The \"\"Big\"\" Cafe, Main\",\"line one\nline two\",4.50,\r\n2026-10-16,\"End\",,1.00,"
    rows = plan(text).rows
    assert_equal [ "The \"Big\" Cafe, Main", "End" ], rows.map(&:payee)
    assert_equal "line one\nline two", rows.first.memo
    assert_empty plan(text).problems
  end
end
