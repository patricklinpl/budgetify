# Deleting a category or group (issue #56, CAT-03, CAT-04, CAT-06).
#
# Reference behavior (T): an empty category deletes without a prompt; a
# category with history needs a replacement and every transaction, assigned
# amount and remaining availability moves to it; a group with only
# assignments (no history) deletes after a confirmation that returns those
# assignments to Ready to Assign. Anything else is refused atomically with
# the impact, never silently dropped. Target (goal) migration is U in the
# reference, so a category that has a target is refused until the target is
# removed explicitly. Hidden replacements are untested in the reference and
# are refused with a reason rather than guessed.
class CategoryRemoval
  class Blocked < StandardError
    attr_reader :impact

    def initialize(message, impact = nil)
      super(message)
      @impact = impact
    end
  end

  # Counts what deleting these categories touches.
  def self.impact(categories)
    ids = categories.map(&:id)
    rows = MonthCategory.where(category_id: ids)
    {
      categories: categories.size,
      transactions: Transaction.not_deleted.where(category_id: ids).count,
      split_lines: SubTransaction.not_deleted.where(category_id: ids).count,
      scheduled_transactions: ScheduledTransaction.not_deleted.where(category_id: ids).count +
        ScheduledSubTransaction.where(category_id: ids).count,
      money_movements: MoneyMovement.not_deleted.where("from_category_id IN (:ids) OR to_category_id IN (:ids)", ids: ids).count,
      targets: categories.count { |category| category.goal_type.present? || !category.goal_target.nil? },
      assigned: rows.sum(:budgeted),
      activity: rows.sum(:activity),
      available: rows.sum(:budgeted) + rows.sum(:activity)
    }
  end

  def self.history?(impact)
    impact[:transactions].positive? || impact[:split_lines].positive? ||
      impact[:scheduled_transactions].positive? || impact[:money_movements].positive? ||
      !impact[:activity].zero?
  end

  def self.delete_category!(category, replacement: nil, return_assigned: false)
    new([ category ], replacement, return_assigned, group: nil).call
  end

  def self.delete_group!(group, replacement: nil, return_assigned: false)
    new(group.categories.not_deleted.to_a, replacement, return_assigned, group: group).call
  end

  def initialize(categories, replacement, return_assigned, group:)
    @categories = categories
    @replacement = replacement
    @return_assigned = return_assigned
    @group = group
  end

  def call
    budget = @categories.first&.budget || @group.budget
    impact = self.class.impact(@categories)
    guard!(impact)

    Category.transaction do
      migrate!(budget) if @replacement
      MonthCategory.where(category_id: @categories.map(&:id)).delete_all
      @categories.each { |category| category.update!(deleted: true) }
      @group&.update!(deleted: true)
      budget.categories.not_deleted.where.not(payment_account_id: nil).find_each { |c| c.update_column(:knowledge, budget.next_knowledge!) }
    end
    impact.merge(migrated_to: @replacement&.public_id)
  end

  private
    def guard!(impact)
      if @categories.any? { |c| c.internal? || c.payment? }
        raise Blocked.new("Internal and Credit Card Payment categories cannot be deleted.", impact)
      end
      if @group&.internal?
        raise Blocked.new("Internal category groups cannot be deleted.", impact)
      end

      if impact[:targets].positive?
        raise Blocked.new("A category being deleted has a target. Target behavior on delete is not established, so remove the target first (set goal_target to null) instead of losing it silently.", impact)
      end

      if @replacement
        raise Blocked.new("The replacement must be a visible, active category in a visible group, outside the deleted ones. Moving money into hidden or deleted places is not supported.", impact) if invalid_replacement?
      elsif self.class.history?(impact)
        raise Blocked.new("These categories have transactions, scheduled items, activity or money movements. Choose a replacement category to move them to.", impact)
      elsif !impact[:assigned].zero? && !@return_assigned
        raise Blocked.new("These categories have money assigned. Confirm to return it to Ready to Assign, or choose a replacement category.", impact)
      end
    end

    def invalid_replacement?
      @replacement.deleted? || @replacement.internal? || @replacement.payment? ||
        @replacement.hidden? || @replacement.category_group.deleted? || @replacement.category_group.hidden? ||
        @replacement.budget_id != (@categories.first&.budget_id || @group.budget_id) ||
        @categories.map(&:id).include?(@replacement.id)
    end

    def migrate!(budget)
      ids = @categories.map(&:id)
      Transaction.not_deleted.where(category_id: ids).find_each { |t| t.update!(category_id: @replacement.id) }
      SubTransaction.not_deleted.where(category_id: ids).find_each { |s| s.update!(category_id: @replacement.id) }
      ScheduledTransaction.not_deleted.where(category_id: ids).find_each { |s| s.update!(category_id: @replacement.id) }
      ScheduledSubTransaction.where(category_id: ids).find_each { |s| s.update!(category_id: @replacement.id) }
      MoneyMovement.not_deleted.where(from_category_id: ids).find_each { |m| m.update!(from_category_id: @replacement.id) }
      MoneyMovement.not_deleted.where(to_category_id: ids).find_each { |m| m.update!(to_category_id: @replacement.id) }
      MonthCategory.where(category_id: ids).find_each do |row|
        target = MonthCategory.find_or_initialize_by(category_id: @replacement.id, month: row.month)
        target.budgeted = target.budgeted.to_i + row.budgeted
        target.activity = target.activity.to_i + row.activity
        target.credit_activity = target.credit_activity.to_i + row.credit_activity
        target.save!
      end
    end
end
