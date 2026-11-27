# Numbers for the plan header pill and the Summary panel (issue #56 plan
# header). [reference] The reference Summary lists Left Over from Last Month,
# Assigned, Activity and Available, and the header shows Ready to Assign.
# [engineering] Assigned, Activity and Available are the sums of the category
# rows in the grid (unfiltered, so a chip filter does not change them), and Left
# Over is the remainder, so the four always add up. Ready to Assign is the same
# figure the API reports for the month. Nothing is written.
class PlanFigures
  def self.build(budget, grid, month: Date.current.beginning_of_month)
    assigned = grid.sum { |group| group[:assigned] }
    activity = grid.sum { |group| group[:activity] }
    available = grid.sum { |group| group[:available] }
    {
      ready_to_assign: MonthSerializer.new(budget, month).as_json.fetch(:to_be_budgeted),
      left_over: available - assigned - activity,
      assigned: assigned,
      activity: activity,
      available: available
    }
  end
end
