# Reset Available Amount (issue #58 AUTO-RESET-01). Reference vector (T):
# Dining assigned 0 / activity +10 / available 10 -> assigned -10 / available
# 0, Ready to Assign +10, activity unchanged.
#
# This is an assignment change, not a transaction: it lowers the category's
# Assigned for the month by its Available and writes the same assignment
# ledger row as any assignment decrease (MonthAssignment: category -> Ready
# to Assign). No transaction, account balance or activity changes.
#
# Not covered by the audit (U), so refused instead of guessed: zero or
# negative Available, payment/internal/hidden categories, months other than
# the current one, and the other reset/average modes.
class ResetAvailable
  class Refused < StandardError; end

  def self.available(category, month)
    CategorySerializer.as_json(category, month: month)[:balance].to_i
  end

  def self.reset!(budget:, category:, month:, user:, expected_available:, history: nil)
    raise Refused, "Choose a category from this plan." unless category.budget_id == budget.id && !category.deleted
    raise Refused, "Only the current month can be reset." unless month == Date.current.beginning_of_month
    raise Refused, "This category cannot be reset." if category.internal || category.payment_account_id || category.hidden
    raise Refused, "The available amount changed. Review and try again." unless expected_available.is_a?(Integer)

    budget.transaction do
      Category.where(id: category.id).lock.to_a
      current = available(category, month)
      raise Refused, "The available amount changed. Review and try again." if current != expected_available
      raise Refused, "There is no positive available amount to reset." unless current.positive?

      before = UndoSnapshot.reset_image(category, month)
      assigned = category.month_category_for(month).budgeted.to_i
      MonthAssignment.set!(budget: budget, category: category, month: month, amount: assigned - current, user: user)
      record!(history, category, month, before)
      current
    end
  end

  # The Undo step keeps only the reset figures of this category (no
  # transactions): Undo restores assigned from the before image and refuses
  # when anything it relied on drifted. Activity is guarded, never written.
  def self.record!(history, category, month, before)
    return if history.nil?

    after = UndoSnapshot.reset_image(category, month)
    history.record!(kind: :reset, before: { "tx" => {}, "sub" => {}, "reset" => before }, after: { "tx" => {}, "sub" => {}, "reset" => after })
  end
end
