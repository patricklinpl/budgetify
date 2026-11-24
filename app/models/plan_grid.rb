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
end
