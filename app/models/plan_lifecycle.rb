# Plan lifecycle operations (issue #54): creating a plan with its initial
# categories, and Fresh Start. Reuses the existing plan, account, category
# and scheduled transaction models; nothing here changes money arithmetic.
class PlanLifecycle
  # Initial categories for a new plan. This is a product choice recorded on
  # the PR: the audit says "initial default categories exist" without
  # listing them.
  DEFAULT_CATEGORY_GROUPS = {
    "Bills" => [ "Rent/Mortgage", "Electric", "Water", "Internet" ],
    "Needs" => [ "Groceries", "Transportation" ],
    "Wants" => [ "Dining Out", "Fun Money" ]
  }.freeze

  # Plans accept names up to this length so the archived name fits.
  MAX_NAME_LENGTH = 100
  DATE_FORMATS = %w[MM/DD/YYYY DD/MM/YYYY YYYY-MM-DD DD.MM.YYYY].freeze

  def self.create_plan(user, name:)
    Budget.transaction do
      plan = user.budgets.create!(name: name)
      DEFAULT_CATEGORY_GROUPS.each do |group_name, category_names|
        group = plan.category_groups.create!(name: group_name)
        category_names.each { |category_name| group.categories.create!(budget: plan, name: category_name) }
      end
      plan
    end
  end

  def self.archived_name(name, on: Date.current)
    "#{name} (archived #{on.iso8601})"
  end

  # Fresh Start: the original plan keeps its identity, history and balances
  # under an archived name. A new plan takes the original name with the same
  # formats, categories and groups (including targets), open accounts at
  # zero with no transactions, and scheduled transactions. Posted
  # transactions, assignments and balances do not carry.
  def self.fresh_start(original, name: nil)
    Budget.transaction do
      new_name = name.presence || original.name
      original.update!(name: archived_name(original.name))
      fresh = original.user.budgets.create!(name: new_name, date_format: original.date_format,
        currency_format: original[:currency_format])
      account_map = copy_accounts(original, fresh)
      category_map = copy_categories(original, fresh)
      copy_scheduled_transactions(original, fresh, account_map, category_map)
      fresh
    end
  end

  def self.copy_accounts(original, fresh)
    original.accounts.not_deleted.where(closed: false).order(:id).each_with_object({}) do |account, map|
      map[account.id] = fresh.accounts.create!(name: account.name, type: account.type,
        on_budget: account.on_budget, note: account.note).id
    end
  end

  GOAL_FIELDS = %w[goal_type goal_target goal_target_date goal_cadence goal_cadence_frequency
    goal_day goal_creation_month goal_needs_whole_amount].freeze

  def self.copy_categories(original, fresh)
    map = {}
    groups = original.category_groups.not_deleted.where(internal: false)
      .where.not(name: Budget::CREDIT_CARD_PAYMENTS_GROUP_NAME).order(:id)
    groups.each do |group|
      new_group = fresh.category_groups.create!(name: group.name, hidden: group.hidden)
      group.categories.not_deleted.where(internal: false, payment_account_id: nil).order(:id).each do |category|
        attributes = category.attributes.slice("name", "hidden", "note", *GOAL_FIELDS)
        map[category.id] = new_group.categories.create!(attributes.merge("budget" => fresh)).id
      end
    end
    map
  end

  def self.copy_scheduled_transactions(original, fresh, account_map, category_map)
    payee_ids = {}
    payee_for = lambda do |payee|
      next nil if payee.nil? || payee.transfer_account_id.present?

      payee_ids[payee.id] ||= fresh.payees.not_deleted.find_by(name: payee.name)&.id ||
        fresh.payees.create!(name: payee.name).id
    end
    original.scheduled_transactions.not_deleted.order(:id).each do |scheduled|
      account_id = account_map[scheduled.account_id]
      next if account_id.nil?
      next if scheduled.transfer_account_id && account_map[scheduled.transfer_account_id].nil?

      copy = fresh.scheduled_transactions.create!(
        scheduled.attributes.slice("date_first", "date_next", "frequency", "amount", "memo", "flag_color", "flag_name").merge(
          account_id: account_id, payee_id: payee_for.call(scheduled.payee),
          category_id: category_map[scheduled.category_id],
          transfer_account_id: account_map[scheduled.transfer_account_id]
        )
      )
      scheduled.scheduled_sub_transactions.where(deleted: false).each do |sub|
        copy.scheduled_sub_transactions.create!(
          amount: sub.amount, memo: sub.memo, category_id: category_map[sub.category_id],
          payee_id: payee_for.call(sub.payee), transfer_account_id: account_map[sub.transfer_account_id]
        )
      end
    end
  end
  private_class_method :copy_accounts, :copy_categories, :copy_scheduled_transactions
end
