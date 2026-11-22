# Serializes a Category (spec: Category schema = CategoryBase + currency
# triples). Amounts (budgeted/activity/balance) are integer milliunits for
# the given plan month, with *_currency and *_formatted companions (spec:
# CurrencyFormat). Goal fields return null until goals are implemented
# (spec: nullable goal fields).
class CategorySerializer
  def self.as_json(category, month: nil)
    month ||= Date.current.beginning_of_month
    month_category = category.month_category_for(month)
    currency_format = category.budget.currency_format
    # The month's available balance carries over: positive balances roll
    # forward, while cash overspending is absorbed by Ready to Assign and
    # the category restarts at zero (spec: Category.balance).
    balance = 0
    category.month_categories.where("month <= ?", month).order(:month).each do |entry|
      balance += entry.budgeted.to_i + entry.activity.to_i
      balance = 0 if balance.negative?
    end
    {
      id: category.public_id,
      category_group_id: category.category_group.public_id,
      category_group_name: category.category_group.name,
      name: category.name,
      hidden: category.hidden,
      internal: category.internal,
      original_category_group_id: nil,
      note: category.note,
      goal_type: category.goal_type,
      goal_needs_whole_amount: category.goal_needs_whole_amount,
      goal_day: category.goal_day,
      goal_cadence: category.goal_cadence,
      goal_cadence_frequency: category.goal_cadence_frequency,
      goal_creation_month: category.goal_creation_month&.iso8601,
      goal_target: category.goal_target,
      goal_target_month: nil,
      goal_target_date: category.goal_target_date&.iso8601,
      goal_percentage_complete: nil,
      goal_months_to_budget: nil,
      goal_under_funded: nil,
      goal_overall_funded: nil,
      goal_overall_left: nil,
      deleted: category.deleted
    }.merge!(
      Milliunits.fields(:budgeted, month_category.budgeted, currency_format),
      Milliunits.fields(:activity, month_category.activity, currency_format),
      Milliunits.fields(:balance, balance, currency_format),
      goal_target_fields(category, currency_format)
    )
  end

  def self.goal_target_fields(category, currency_format)
    return { goal_target_currency: nil, goal_target_formatted: nil } if category.goal_target.nil?

    Milliunits.fields(:goal_target, category.goal_target, currency_format).except(:goal_target)
  end
end
