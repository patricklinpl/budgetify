# Budget grid rows for a plan month (issue #56): each category with its
# assigned, activity and available amounts, the same figures as the API.
class PlanGrid
  def self.build(budget, show_hidden: false, month: Date.current.beginning_of_month)
    groups = budget.category_groups.not_deleted.where(internal: false).order(:id)
    groups = groups.where(hidden: false) unless show_hidden
    rows = groups.map do |group|
      categories = group.categories.not_deleted.where(internal: false).order(:id)
      categories = categories.where(hidden: false) unless show_hidden
      lines = categories.map do |category|
        data = CategorySerializer.as_json(category, month: month)
        { category: category, assigned: data[:budgeted], activity: data[:activity], available: data[:balance] }
      end
      { group: group, rows: lines,
        assigned: lines.sum { |r| r[:assigned] }, activity: lines.sum { |r| r[:activity] }, available: lines.sum { |r| r[:available] } }
    end
    [ rows, budget.categories.not_deleted.where(internal: false, hidden: true).count ]
  end

  # #59 VIEW-FILTER-01. Only the two chips whose reference vectors are known are
  # built: Overspent is Available below zero, Money Available is Available above
  # zero (zero and negative rows are excluded). Underfunded, Overfunded and
  # Snoozed predicates were not pinned by the audit and stay unbuilt.
  # [engineering] Groups with no matching row are dropped, and a shown group's
  # totals are summed over the rows that are shown. Nothing is written.
  FILTERS = {
    "overspent" => ->(line) { line[:available].negative? },
    "money_available" => ->(line) { line[:available].positive? }
  }.freeze

  def self.filter(rows, key)
    test = FILTERS.fetch(key)
    hidden = 0
    kept = rows.filter_map do |entry|
      lines = entry[:rows].select(&test)
      hidden += entry[:rows].size - lines.size
      next if lines.empty?
      entry.merge(rows: lines, assigned: lines.sum { |r| r[:assigned] },
        activity: lines.sum { |r| r[:activity] }, available: lines.sum { |r| r[:available] })
    end
    [ kept, hidden ]
  end
end
