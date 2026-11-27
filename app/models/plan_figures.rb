# Numbers for the plan header pill and the Summary panel (issue #56 plan
# header). [reference] The reference Summary lists Left Over from Last Month,
# Assigned, Activity and Available, and the header shows Ready to Assign.
# [engineering] Assigned, Activity and Available are the sums of every category
# row in the grid, hidden categories included (the caller passes the grid built
# with show_hidden: true, so neither a chip filter nor the hidden toggle changes
# them), and Left
# Over is the remainder, so the four always add up. Ready to Assign is the same
# figure the API reports for the month.
#
# Cost to Be Me (this file's `targets`): [reference] the reference panel lists
# the month's targets total under that heading. [engineering] Only the one
# built target kind counts (a monthly set-aside amount, see MonthlyTarget), over
# every non-deleted category including hidden ones; other target kinds are not
# built so they add nothing. Nothing is written.
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
      available: available,
      targets: grid.sum { |group| group[:rows].sum { |row| MonthlyTarget.monthly?(row[:category]) ? row[:category].goal_target.to_i : 0 } }
    }
  end
end
