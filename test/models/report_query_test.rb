require "test_helper"

# #64 slice 1: report arithmetic, no UI. [reference T] marks a number the audit
# recorded; [engineering] marks a mapping or rounding choice the audit does not
# pin. Fixtures are synthetic. REPORT-LOAN-01 and the loan parts of REPORT-06 and
# REPORT-09 are not covered: they need loan paired categories (#66).
class ReportQueryTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Date.new(2026, 11, 30)
    @user = User.create!(email_address: "reports@example.com", password: "password123")
    @plan = @user.budgets.create!(name: "Reports plan")
    @writer = TransactionWriter.new(@plan)
    @cash = Account.open!(budget: @plan, attributes: { "name" => "Cash", "type" => "cash", "balance" => 1_000_000 })
    @card_a = Account.open!(budget: @plan, attributes: { "name" => "CardA", "type" => "creditCard", "balance" => 0 })
    @card_b = Account.open!(budget: @plan, attributes: { "name" => "CardB", "type" => "creditCard", "balance" => 0 })
    group = @plan.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @plan, name: "Groceries")
    @dining = group.categories.create!(budget: @plan, name: "Dining")
    @inflow = @plan.categories.find_by!(internal: true, name: Budget::INFLOW_CATEGORY_NAME)
  end

  teardown { travel_back }

  def put(account, amount, date: "2026-11-10", category: nil, extra: {})
    attributes = { "account_id" => account.public_id, "date" => date, "amount" => amount }
    attributes["category_id"] = category.public_id if category
    @writer.persist_new!(@writer.build(attributes.merge(extra)))
  end

  def query(start: Date.new(2026, 11, 1), finish: start, **filters) = ReportQuery.new(@plan, start_month: start, end_month: finish, **filters)

  def baseline
    put(@cash, -10_000, category: @groceries)
    put(@card_a, -100_000, category: @groceries)
    put(@card_b, -100_000, category: @groceries)
  end

  test "[reference T] REPORT-01: spending 210, income 0, net -210, Net Worth 790, starting balance not income" do
    baseline
    report = query
    assert_equal 210_000, report.spending_total
    assert_equal 0, report.income_total
    assert_equal(-210_000, report.net_total)
    assert_equal({ assets: 990_000, debts: 200_000, net_worth: 790_000 }, report.net_worth(on: Date.new(2026, 11, 1)))
    assert_equal [ @card_a.id, @card_b.id ], report.spending_rows.select { |r| r.amount == 100_000 }.map { |r| r.account.id }.sort
  end

  test "[reference T] REPORT-02 shape: a reconciliation difference is negative income, tracking never counts as spending" do
    baseline
    put(@cash, -50_000, category: @dining)
    tracking = Account.open!(budget: @plan, attributes: { "name" => "House", "type" => "otherAsset", "balance" => 0 })
    put(tracking, -12_340)
    @cash.reconcile!(entered: @cash.reload.cleared_balance - 5_000)
    report = query
    assert_equal 260_000, report.spending_total
    assert_equal(-5_000, report.income_total)
    assert_equal(-265_000, report.net_total)
    assert_equal 0, report.spending_rows.count { |r| r.account.id == tracking.id }
  end

  test "[reference T] REPORT-03 shape: Net Worth with and without the tracking account" do
    baseline
    tracking = Account.open!(budget: @plan, attributes: { "name" => "House", "type" => "otherLiability", "balance" => 0 })
    put(tracking, -12_340)
    on = Date.new(2026, 11, 30)
    assert_equal({ assets: 990_000, debts: 212_340, net_worth: 777_660 }, query.net_worth(on: on))
    assert_equal({ assets: 990_000, debts: 200_000, net_worth: 790_000 }, query.net_worth(on: on, include_tracking: false))
  end

  test "[reference T] REPORT-04 shape: category and account filters, averages, reset" do
    put(@cash, -30_000, category: @groceries)
    put(@cash, -10_000, category: @dining)
    put(@card_a, -100_000, category: @dining)
    all = query
    assert_equal 140_000, all.spending_total
    only_groceries = query(category_ids: [ @groceries.id ])
    assert_equal 30_000, only_groceries.spending_total
    assert_equal 1, only_groceries.spending_rows.size
    assert_equal 100_000, query(account_ids: [ @card_a.id ]).spending_total
    assert_equal 100, ReportQuery::Rounding.cents(only_groceries.daily_average) # 30.00 / 30 days = 1.00 (cents)
    assert_equal 333, ReportQuery::Rounding.cents(query(account_ids: [ @card_a.id ]).daily_average) # 100.00 / 30 = 3.33
    assert_equal 140_000, query(account_ids: nil, category_ids: nil).spending_total # reset
  end

  test "[reference T] REPORT-06 and 07 windows: Oct-Nov divisors, deleting the October row keeps the range" do
    put(@cash, -300_000, category: @dining)
    put(@cash, -33_210, category: @groceries)
    october = put(@cash, -20_000, date: "2026-10-15", category: @groceries)
    report = query(start: Date.new(2026, 10, 1), finish: Date.new(2026, 11, 1))
    assert_equal [ 2, 61 ], [ report.months, report.days ]
    assert_equal 353_210, report.spending_total
    assert_equal 17_660, ReportQuery::Rounding.cents(report.monthly_average)
    assert_equal 579, ReportQuery::Rounding.cents(report.daily_average)
    assert_equal({ Date.new(2026, 10, 1) => 20_000, Date.new(2026, 11, 1) => 333_210 }, report.spending_by_month)

    @writer.destroy!(october)
    after = query(start: Date.new(2026, 10, 1), finish: Date.new(2026, 11, 1))
    assert_equal 333_210, after.spending_total
    assert_equal 16_660, ReportQuery::Rounding.cents(after.monthly_average) # empty October still counts in the divisor
    assert_equal 546, ReportQuery::Rounding.cents(after.daily_average)
    this_month = query
    assert_equal [ 1, 30 ], [ this_month.months, this_month.days ]
    assert_equal 1_111, ReportQuery::Rounding.cents(this_month.daily_average)
  end

  test "[reference T] REPORT-07 deviations: -156.60 / +156.60 / 88.7%" do
    avg = Rational(353_210, 2)
    assert_equal(-15_660, ReportQuery::Rounding.cents(20_000 - avg))
    assert_equal 15_660, ReportQuery::Rounding.cents(333_210 - avg)
    assert_equal 88.7, ReportQuery::Rounding.percent_tenths(333_210 - avg, avg)
  end

  test "[reference T] REPORT-08 percent: -9983.21 over -20.00 is -49916.1%, base sign ignored" do
    assert_equal(-49_916.1, ReportQuery::Rounding.percent_tenths(-9_983_210, -20_000))
    assert_nil ReportQuery::Rounding.percent_tenths(5, 0)
  end

  test "[engineering] ties: money to the even cent, percent away from zero (audit pins only the tie values above)" do
    assert_equal 17_660, ReportQuery::Rounding.cents(176_605)
    assert_equal 17_662, ReportQuery::Rounding.cents(176_615)
    assert_equal(-17_660, ReportQuery::Rounding.cents(-176_605))
  end

  test "[engineering] a split counts through its sub-transactions, a card payment transfer is not spending, refunds reduce spending, inflow and payment categories are excluded" do
    put(@cash, -30_000, extra: { "subtransactions" => [
      { "amount" => -10_000, "category_id" => @groceries.public_id }, { "amount" => -20_000, "category_id" => @dining.public_id } ] })
    put(@card_a, -100_000, category: @groceries)
    payment = put(@cash, -40_000, extra: { "transfer_account_id" => @card_a.public_id })
    put(@cash, 5_000, category: @groceries)
    put(@cash, 70_000, category: @inflow)
    report = query
    assert_equal({ @groceries => 105_000, @dining => 20_000 }, report.spending_by_category)
    assert_equal 125_000, report.spending_total
    assert_equal 70_000, report.income_total
    assert_nil payment.reload.category
    assert_equal 125_000, report.spending_by_group.values.sum
  end

  test "[engineering] rows that should never be categorized (tracking account, payment category) are still not spending even if stored that way" do
    tracking = Account.open!(budget: @plan, attributes: { "name" => "House", "type" => "otherAsset", "balance" => 0 })
    @plan.transactions.create!(account: tracking, date: Date.new(2026, 11, 5), amount: -7_000, category: @groceries, cleared: "cleared", approved: true)
    @plan.transactions.create!(account: @cash, date: Date.new(2026, 11, 5), amount: -8_000, category: @card_a.payment_category, cleared: "cleared", approved: true)
    parent = @plan.transactions.create!(account: @cash, date: Date.new(2026, 11, 6), amount: -3_000, cleared: "cleared", approved: true)
    parent.sub_transactions.create!(amount: -3_000, category: @card_a.payment_category)
    assert_equal 0, query.spending_total
    assert_empty query.spending_rows
  end

  test "[engineering] deleted rows and other plans are ignored and an inverted range is refused" do
    deleted = put(@cash, -9_000, category: @groceries)
    @writer.destroy!(deleted)
    other_user = User.create!(email_address: "other-reports@example.com", password: "password123")
    other = other_user.budgets.create!(name: "Other")
    assert_equal 0, ReportQuery.new(other, start_month: Date.new(2026, 11, 1)).spending_total
    assert_equal 0, query.spending_total
    assert_raises(ArgumentError) { query(start: Date.new(2026, 11, 1), finish: Date.new(2026, 10, 1)) }
  end

  # [engineering] Real write path only: a transfer Cash -> personal loan with a
  # user-picked ordinary category. Budgetify has no loan paired category (#66),
  # so this is NOT reference REPORT-LOAN-01 parity. It records current writer
  # behavior: the categorized transfer row counts as spending, the loan-side
  # mirror carries no category, and no payment category exists for the loan.
  test "[engineering] categorized transfer to a loan counts as spending, not reference paired-category parity" do
    loan = Account.open!(budget: @plan, attributes: { "name" => "Loan", "type" => "personalLoan", "balance" => -500_000 })
    audit = @plan.category_groups.create!(name: "TEST Audit").categories.create!(budget: @plan, name: "Loan payment")
    row = put(@cash, -300_000, category: audit, extra: { "transfer_account_id" => loan.public_id })
    assert_equal loan, row.reload.transfer_account
    assert_nil row.transfer_transaction.category
    assert_nil loan.payment_category
    assert_equal 300_000, query.spending_total
    assert_equal 300_000, query.spending_rows.sum(&:amount)
  end
end
