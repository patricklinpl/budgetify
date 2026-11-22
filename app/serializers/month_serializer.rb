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
    # Assign" (spec: MonthSummary.activity).
    def activity
      month_categories.where(categories: { internal: false }, month: @month).sum(:activity)
    end

    def to_be_budgeted
      through = month_categories.where("month <= ?", @month)
      through.where(categories: { internal: true }).sum(:activity) -
        through.where(categories: { internal: false }).sum(:budgeted)
    end
end
