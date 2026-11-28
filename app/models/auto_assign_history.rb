# Average Assigned and Average Spent for the Auto-Assign panel.
# [reference] Source: YNAB's Auto-Assign help page. Average Assigned is a rolling
# average of the assigned amount of a category over up to the last 12 months,
# starting from the first month money was assigned to it, with the current month
# left out. Average Spent is the same over up to 12 months, starting from the
# first month in that window in which the category was assigned or spent money.
# [reference] Observed with synthetic data in the reference panel: assigning $20
# and $40 in two earlier months showed Average Assigned $30.00, and spending $10
# and $25 showed Average Spent $17.50, with an empty month before them not
# counted.
# [engineering] The panel figure is the sum of the per-category averages, each
# rounded half-even to the milliunit (the app's money tie rule). A month between
# the first active month and last month counts as zero. Spending is a positive
# amount, so a refund lowers it. Credit card payment categories use their
# derived Activity, like the Activity column. Not observed in the reference:
# gap months inside the range, the 12-month cut-off, and refunds. Nothing is
# written.
class AutoAssignHistory
  WINDOW_MONTHS = 12

  def self.averages(categories, month:)
    first = month << WINDOW_MONTHS
    last = month.prev_month
    months = (0...WINDOW_MONTHS).map { |offset| first >> offset }
    stored = MonthCategory.where(category_id: categories.map(&:id), month: first..last).group_by(&:category_id)
    funding = CreditCardFunding.new(categories.first.budget) if categories.any?(&:payment?)
    totals = { assigned: 0, spent: 0 }
    categories.each do |category|
      rows = stored.fetch(category.id, []).index_by(&:month)
      assigned = months.map { |m| rows[m]&.budgeted.to_i }
      spent = months.map { |m| -(category.payment? ? funding.payment_activity(category.payment_account_id, m) : rows[m]&.activity.to_i) }
      totals[:assigned] += average(assigned) { |a| a.nonzero? }
      totals[:spent] += average(spent.zip(assigned)) { |s, a| s.nonzero? || a.nonzero? }
    end
    totals
  end

  # Mean of the values from the first month that passes the block to the end,
  # as whole milliunits (ties to even). Zero when no month qualifies.
  def self.average(values)
    start = values.index { |value| yield(*value) }
    return 0 if start.nil?
    series = values[start..]
    sum = series.sum { |value| value.is_a?(Array) ? value.first : value }
    (Rational(sum, series.size)).round(half: :even)
  end
  private_class_method :average
end
