# Sets a category's Assigned amount for a plan month and records the money
# movement between Ready to Assign and the category (shared by the API and the
# budget grid so both write the same rows).
class MonthAssignment
  def self.set!(budget:, category:, month:, amount:, user:)
    month_category = category.month_category_for(month)
    previous = month_category.budgeted.to_i
    month_category.budgeted = amount
    return month_category unless month_category.save

    delta = month_category.budgeted.to_i - previous
    record_movement(budget, category, month, delta, user)
    month_category
  end

  def self.record_movement(budget, category, month, delta, user)
    return if delta.zero?

    group = budget.money_movement_groups.create!(group_created_at: Time.current, month: month, performed_by_user: user)
    budget.money_movements.create!(
      money_movement_group: group, month: month, moved_at: Time.current, performed_by_user: user,
      from_category: delta.negative? ? category : nil, to_category: delta.negative? ? nil : category, amount: delta.abs
    )
  end
end
