# Serializes plan months (spec: MonthSummary / MonthDetail schemas).
# Month rollups are computed from the plan's per-month category amounts
# (month_categories, the categories issue's storage decision):
# income is the month's activity on the internal "Inflow: Ready to
# Assign" category, budgeted the month's assigned total, activity the
# month's total excluding Ready-to-Assign inflows, and to_be_budgeted
# the cumulative Ready to Assign (income minus budgeted through the
# month, spec: MonthSummary.to_be_budgeted). age_of_money stays null
# until that metric is implemented (spec: nullable); months are never
# deleted here, so deleted is always false (spec: MonthSummary.deleted).
class MonthSerializer
  def self.summary_as_json(budget, month)
    new(budget, month).as_json
  end

  # MonthDetail = MonthSummary + categories: every category with amounts
  # specific to the requested month (spec: MonthDetail.categories).
  def self.detail_as_json(budget, month)
    new(budget, month).as_json.merge(
      categories: budget.categories.not_deleted.includes(:category_group, :month_categories).map { |category| CategorySerializer.as_json(category, month: month) }
    )
  end

  def initialize(budget, month)
    @budget = budget
    @month = month
  end

  def as_json
    currency_format = @budget.currency_format
    {
      month: @month.iso8601,
      note: nil,
      **Milliunits.fields(:income, income, currency_format),
      **Milliunits.fields(:budgeted, budgeted, currency_format),
      **Milliunits.fields(:activity, activity, currency_format),
      **Milliunits.fields(:to_be_budgeted, to_be_budgeted, currency_format),
      age_of_money: nil,
      deleted: false
    }
  end

  private
    def month_categories
      MonthCategory.joins(:category).where(categories: { budget_id: @budget.id })
    end

    # Inflows are recorded as activity on the internal "Inflow: Ready to
    # Assign" category (spec: MonthSummary.income).
    def income
      month_categories.where(categories: { internal: true }, month: @month).sum(:activity)
    end

    def budgeted
      month_categories.where(categories: { internal: false }, month: @month).sum(:budgeted)
    end

    # Activity excludes transactions categorized to "Inflow: Ready to
    # Assign" (spec: MonthSummary.activity). Credit Card Payment category
    # movements are excluded too: no transactions are categorized to them
    # (spec: SaveTransaction.category_id), so they are not "transactions
    # categorized" in the month.
    def activity
      month_categories.where(categories: { internal: false }, month: @month).sum(:activity)
    end

    # Ready to Assign is cumulative: income minus budgeted through the
    # month. The cash part of a month's category shortfall is deducted
    # from the FOLLOWING month's Ready to Assign (the category stays
    # negative in its overspent month and restarts at zero); the credit
    # part does not reduce Ready to Assign - it becomes credit-card
    # payment underfunding (YNAB docs: cash vs credit overspending;
    # spec: MonthSummary.to_be_budgeted).
    def to_be_budgeted
      # Transfers from credit (debt) accounts into cash accounts bring new
      # money into the plan, increasing Ready to Assign (YNAB's "Inflow
      # from Debt Account"; docs: Credit Card Cash Advances: An Overview).
      # Cumulative through the month like the rest of the walk. Card
      # payments (cash -> credit) and balance transfers (credit ->
      # credit) move existing money or debt only, so neither counts.
      total = debt_inflow_through(@month)
      walk_entries_by_category.each_value do |entries|
        balance = 0
        entries.each do |entry|
          if entry.internal
            total += entry.activity
            next
          end

          balance += entry.budgeted + entry.activity
          total -= entry.budgeted
          next if entry.month >= @month
          next unless balance.negative?

          cash, _credit = MonthCategory.overspend_split(balance, entry.activity, entry.credit_activity)
          total -= cash
          balance = 0
        end
      end
      total
    end

    # Normalized month rows for the Ready-to-Assign walk: stored month
    # rows plus synthesized rows for Credit Card Payment categories,
    # whose activity is derived (CreditCardFunding). A red payment
    # category is cash overspending (YNAB docs: When Your Credit Card
    # Payment Category is Red), so synthesized rows are all-cash.
    MonthWalkEntry = Struct.new(:month, :budgeted, :activity, :credit_activity, :internal)

    def walk_entries_by_category
      stored = month_categories.includes(:category).where("month <= ?", @month).order(:month).group_by(&:category_id)
      entries_by_category = stored.transform_values do |entries|
        entries.map { |entry| MonthWalkEntry.new(entry.month, entry.budgeted.to_i, entry.activity.to_i, ledger.category_credit_activity(entry.category_id, entry.month), entry.category.internal?) }
      end

      @budget.categories.not_deleted.where.not(payment_account_id: nil).each do |category|
        stored_budgeted = (entries_by_category.delete(category.id) || []).to_h { |entry| [ entry.month, entry.budgeted ] }
        months = (stored_budgeted.keys + funding.active_months(category.payment_account_id, upto: @month)).uniq.sort
        entries_by_category[category.id] = months.map do |entry_month|
          MonthWalkEntry.new(entry_month, stored_budgeted.fetch(entry_month, 0), funding.payment_activity(category.payment_account_id, entry_month), 0, false)
        end
      end
      entries_by_category
    end

    def funding
      @funding ||= CreditCardFunding.new(@budget)
    end

    # Cumulative milliunits transferred from the plan's credit accounts
    # into its cash accounts through the month (the cash-account side of
    # those transfers; each transfer pair is counted once, on that side).
    def debt_inflow_through(month)
      ledger.debt_inflow_through(month)
    end

    def ledger
      @ledger ||= CreditCardLedger.new(@budget)
    end
end
