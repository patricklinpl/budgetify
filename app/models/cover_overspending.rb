# Covers a category's overspending from another category (issue #57
# MONEY-04). The reference-tested vector is full deficit coverage only:
# the target's negative Available is brought to exactly 0 by moving that
# amount of Assigned from the source to the target, in one transaction,
# with one money movement row from the source to the target. Total
# Assigned, Ready to Assign and account balances do not change.
#
# Not covered by the audit (U), so refused instead of guessed: partial or
# arbitrary-amount moves, a source with less Available than the deficit,
# payment categories as either side, and months other than the current one.
class CoverOverspending
  class Refused < StandardError; end

  def self.deficit(budget, category, month)
    balance = CategorySerializer.as_json(category, month: month)[:balance].to_i
    balance.negative? ? -balance : 0
  end

  def self.available(budget, category, month)
    CategorySerializer.as_json(category, month: month)[:balance].to_i
  end

  # Categories that can cover `target`: another normal category whose
  # Available is at least the whole deficit.
  def self.sources(budget, target, month)
    needed = deficit(budget, target, month)
    return [] if needed.zero?

    eligible(budget).where.not(id: target.id).select { |category| available(budget, category, month) >= needed }
  end

  def self.eligible(budget)
    budget.categories.not_deleted.where(internal: false, payment_account_id: nil).includes(:category_group)
  end

  def self.cover!(budget:, target:, source:, month:, user:)
    raise Refused, "Choose a different category to cover from." if source.nil? || source.id == target.id

    budget.transaction do
      # Lock both month rows' categories so concurrent moves cannot both use the same Available.
      Category.where(id: [ target.id, source.id ]).order(:id).lock.to_a
      needed = deficit(budget, target, month)
      raise Refused, "#{target.name} is not overspent, so there is nothing to cover." if needed.zero?
      raise Refused, "#{source.name} has only #{budget.currency_format.format_milliunits(available(budget, source, month))} available, less than the whole overspending." if available(budget, source, month) < needed

      from = source.month_category_for(month)
      to = target.month_category_for(month)
      from.budgeted = from.budgeted.to_i - needed
      to.budgeted = to.budgeted.to_i + needed
      from.save!
      to.save!
      group = budget.money_movement_groups.create!(group_created_at: Time.current, month: month, performed_by_user: user)
      budget.money_movements.create!(
        money_movement_group: group, month: month, moved_at: Time.current, performed_by_user: user,
        from_category: source, to_category: target, amount: needed
      )
      needed
    end
  end
end
