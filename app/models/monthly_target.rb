# Monthly "set aside" target for a category (#58 TARGET-01, partial). Only the
# fixture the audit tested is built: a monthly target of an amount, the
# remaining amount for the current month (target minus Assigned, never below
# zero), assigning that remaining amount, and deleting the target. Refill up
# to, weekly and yearly cadences, dated and custom targets, snoozing and
# funding modes are not built (their formulas are untested or U in the audit).
class MonthlyTarget
  class Refused < StandardError; end

  # Existing goal fields written through the API: a recurring NEED target with
  # cadence 1 (monthly) and no date.
  def self.monthly?(category)
    category.goal_type == "NEED" && category.goal_cadence == 1 && category.goal_target_date.nil? && category.goal_target.to_i.positive?
  end

  def self.any?(category)
    category.goal_type.present? || !category.goal_target.nil?
  end

  def self.assigned(category, month)
    category.month_category_for(month).budgeted.to_i
  end

  def self.remaining(category, month)
    return 0 unless monthly?(category)

    [ category.goal_target.to_i - assigned(category, month), 0 ].max
  end

  def self.set!(category, amount, month:)
    raise Refused, "Enter an amount above zero." unless amount.to_i.positive?
    raise Refused, "This category has a different kind of target. Remove it first; replacing it is not built." if any?(category) && !monthly?(category)

    category.update!(goal_type: "NEED", goal_cadence: 1, goal_cadence_frequency: 1, goal_target: amount,
      goal_target_date: nil, goal_day: nil, goal_creation_month: category.goal_creation_month || month)
  end

  def self.clear!(category)
    category.update!(goal_type: nil, goal_target: nil, goal_target_date: nil, goal_cadence: nil, goal_cadence_frequency: nil,
      goal_day: nil, goal_creation_month: nil, goal_needs_whole_amount: nil)
  end

  # Assigns the remaining amount, bound to the amount the page showed so a
  # stale confirm is refused and nothing changes.
  def self.assign_remaining!(budget:, category:, month:, user:, expected_remaining:)
    raise Refused, "This category has no monthly target." unless monthly?(category)

    category.with_lock do
      remaining = self.remaining(category, month)
      raise Refused, "The remaining amount changed. Review and try again." unless expected_remaining == remaining
      raise Refused, "Nothing remains to assign." if remaining.zero?

      saved = MonthAssignment.set!(budget: budget, category: category, month: month,
        amount: assigned(category, month) + remaining, user: user)
      raise Refused, saved.errors.full_messages.to_sentence if saved.errors.any?

      remaining
    end
  end
end
