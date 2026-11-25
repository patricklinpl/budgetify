# Read-only report arithmetic for Reflect (#64). All money is integer
# milliunits; nothing here writes. Classification (how a Budgetify row maps to
# the reference's spending / income) is an engineering mapping, labeled:
#
#   Spending: category activity of on-budget accounts in ordinary categories
#     (not internal, not a Credit Card Payment category). Outflows are
#     positive spending; a refund into the same category reduces it. A split
#     counts through its sub-transactions. Transfers carry no category, so a
#     card payment is not spending.
#   Income: signed rows in the internal "Inflow: Ready to Assign" category,
#     excluding opening balances. A reconciliation adjustment on an on-budget
#     account lands there, which is how a reconciliation difference shows as
#     negative income (REPORT-02).
#   Tracking accounts carry no category and never count in either.
#
# Loan payments with a paired category (REPORT-LOAN-01) need loan paired
# categories that Budgetify does not create yet (#66); they are not mapped here.
class ReportQuery
  Row = Struct.new(:date, :amount, :category, :account, :transaction, keyword_init: true)

  attr_reader :start_month, :end_month

  def initialize(budget, start_month:, end_month: start_month, account_ids: nil, category_ids: nil)
    @budget = budget
    @start_month = start_month.beginning_of_month
    @end_month = end_month.beginning_of_month
    raise ArgumentError, "end month is before start month" if @end_month < @start_month
    @account_ids = account_ids&.to_a
    @category_ids = category_ids&.to_a
  end

  def first_day = @start_month
  def last_day = @end_month.end_of_month
  def days = (last_day - first_day).to_i + 1
  def months = (@end_month.year * 12 + @end_month.month) - (@start_month.year * 12 + @start_month.month) + 1

  # Spending rows, each with a positive amount for an outflow.
  def spending_rows
    @spending_rows ||= begin
      rows = []
      transactions.where.not(category_id: nil).includes(:category, :account, :sub_transactions).each do |tx|
        next if tx.sub_transactions.any?
        rows << spending_row(tx, tx.category, tx.amount)
      end
      on_scoped_transactions.includes(sub_transactions: :category, account: []).each do |tx|
        tx.sub_transactions.each do |sub|
          next if sub.deleted || sub.category.nil?
          rows << spending_row(tx, sub.category, sub.amount)
        end
      end
      rows.compact
    end
  end

  def spending_total = spending_rows.sum(&:amount)

  def spending_by_category
    spending_rows.group_by(&:category).transform_values { |rows| rows.sum(&:amount) }
  end

  def spending_by_group
    spending_rows.group_by { |row| row.category.category_group }.transform_values { |rows| rows.sum(&:amount) }
  end

  def spending_by_account
    spending_rows.group_by(&:account).transform_values { |rows| rows.sum(&:amount) }
  end

  def spending_by_month
    spending_rows.group_by { |row| row.date.beginning_of_month }.transform_values { |rows| rows.sum(&:amount) }
  end

  # Signed income (an outflow into the inflow category is negative).
  def income_total
    income_rows.sum(&:amount)
  end

  def income_rows
    @income_rows ||= begin
      inflow = @budget.categories.find_by(internal: true, name: Budget::INFLOW_CATEGORY_NAME)
      return [] unless inflow
      scope = on_budget_transactions.where(category_id: inflow.id, opening_balance: false)
      scope = scope.where(account_id: @account_ids) if @account_ids
      scope.includes(:account).map { |tx| Row.new(date: tx.date, amount: tx.amount, category: inflow, account: tx.account, transaction: tx) }
    end
  end

  # Net is income minus expenses (spending).
  def net_total = income_total - spending_total

  # Averages in milliunits, exact (Rational); display rounding is in Rounding.
  def monthly_average(total = spending_total) = Rational(total, months)
  def daily_average(total = spending_total) = Rational(total, days)

  # Net worth at the end of a month: asset accounts and debt accounts, each
  # signed by the account's balance at that date, from non-deleted rows dated on
  # or before the month end. Tracking accounts are included unless excluded.
  def net_worth(on:, include_tracking: true)
    accounts = @budget.accounts.not_deleted
    accounts = accounts.where(on_budget: true) unless include_tracking
    accounts = accounts.where(id: @account_ids) if @account_ids
    sums = @budget.transactions.not_deleted.where(account_id: accounts.select(:id)).where("date <= ?", on.end_of_month).group(:account_id).sum(:amount)
    balances = accounts.map { |account| sums[account.id].to_i }
    assets = balances.select(&:positive?).sum
    debts = -balances.select(&:negative?).sum
    { assets: assets, debts: debts, net_worth: assets - debts }
  end

  # Rounding helpers (engineering, labeled). Money ties go to the even cent
  # (matches the audit's 176.605 -> 176.60, 166.605 -> 166.60 and 156.605 ->
  # 156.60). Percent ties go away from zero (matches the audit's -49916.05% ->
  # -49916.1%). The audit pins only those tie values; other ties are not known.
  module Rounding
    module_function

    # Returns whole cents (Integer) for a milliunit amount (Integer or Rational).
    def cents(milliunits)
      (Rational(milliunits) / 10).round(half: :even)
    end

    def percent_tenths(numerator, denominator)
      return nil if denominator.zero?
      value = Rational(numerator * 1000, denominator.abs)
      value.round(half: :up) / 10.0
    end
  end

  private
    def on_scoped_transactions
      scope = on_budget_transactions
      scope = scope.where(account_id: @account_ids) if @account_ids
      scope
    end

    def transactions
      scope = on_scoped_transactions.where.not(category_id: ordinary_excluded_category_ids)
      scope = scope.where(category_id: @category_ids) if @category_ids
      scope
    end

    def on_budget_transactions
      @budget.transactions.not_deleted.where(date: first_day..last_day)
        .where(account_id: @budget.accounts.where(on_budget: true).select(:id))
    end

    def ordinary_excluded_category_ids
      @budget.categories.where("internal = ? OR payment_account_id IS NOT NULL", true).select(:id)
    end

    def spending_row(tx, category, amount)
      return if category.internal || category.payment?
      return if @category_ids && !@category_ids.include?(category.id)
      Row.new(date: tx.date, amount: -amount, category: category, account: tx.account, transaction: tx)
    end
end
