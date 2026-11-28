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
#
# Auto-Assign rows: [reference] the reference panel lists Assigned Last Month and
# Assigned in Future Months among its rows. [engineering] Assigned Last Month is
# the sum of the previous month's assigned amounts over the categories that are
# not hidden (a category in a hidden group is hidden too). [reference] YNAB's
# Auto-Assign help page says that with no category selected its options leave
# out hidden categories; that page is the source, the reference panel was not
# observed with hidden categories. Assigned in Future Months is the sum of the
# assigned amounts of every month after the viewed month, over every category
# (not covered by that page, so left as it was).
#
# Spent Last Month: [reference] observed in the reference with synthetic data:
# an October with $25 of grocery spending showed Spent Last Month $25.00 in
# November, as a positive number. [engineering] It is the previous month's
# Activity (the same figure the grid shows) summed over the same categories as
# Activity, negated, so spending shows as a positive amount, over the categories
# that are not hidden, like Assigned Last Month. Not observed in the reference:
# a month with refunds or other inflows (here they reduce the total and it can
# go negative) and credit card payments (their category's Activity counts like
# any other row, as it does in Activity). The other rows stay unbuilt.
class PlanFigures
  def self.build(budget, grid, month: Date.current.beginning_of_month)
    assigned = grid.sum { |group| group[:assigned] }
    activity = grid.sum { |group| group[:activity] }
    available = grid.sum { |group| group[:available] }
    categories = grid.flat_map { |group| group[:rows].map { |row| row[:category] } }
    ids = categories.map(&:id)
    shown = grid.reject { |group| group[:group].hidden }.flat_map { |group| group[:rows].map { |row| row[:category] } }.reject(&:hidden)
    {
      ready_to_assign: MonthSerializer.new(budget, month).as_json.fetch(:to_be_budgeted),
      left_over: available - assigned - activity,
      assigned: assigned,
      activity: activity,
      available: available,
      assigned_last_month: MonthCategory.where(category_id: shown.map(&:id), month: month.prev_month).sum(:budgeted),
      spent_last_month: -shown.sum { |category| CategorySerializer.as_json(category, month: month.prev_month).fetch(:activity) },
      assigned_future: MonthCategory.where(category_id: ids).where("month > ?", month).sum(:budgeted),
      targets: grid.sum { |group| group[:rows].sum { |row| MonthlyTarget.monthly?(row[:category]) ? row[:category].goal_target.to_i : 0 } }
    }
  end
end
