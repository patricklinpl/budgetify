# Plan lifecycle operations (issue #54): creating a plan with its initial
# categories, and Fresh Start. Reuses the existing plan, account, category
# and scheduled transaction models; nothing here changes money arithmetic.
class PlanLifecycle
  # Initial categories for a new plan, from the reference's default plan as
  # observed by the verifier (names and group order; Entertainment's emoji
  # and its relative order are unverified, so no emoji is stored). They are
  # ordinary categories and can be renamed, hidden or deleted.
  DEFAULT_CATEGORY_GROUPS = {
    "Bills" => [ "Rent/Mortgage", "Phone & Internet", "Utilities" ],
    "Needs" => [ "Groceries", "Transportation", "Health & Personal Care", "Emergency fund" ],
    "Wants" => [ "Dining out", "Entertainment", "Vacation", "Stuff I forgot to plan for" ]
  }.freeze

  # Plans accept names up to this length so the archived name fits.
  MAX_NAME_LENGTH = 100
  DATE_FORMATS = %w[MM/DD/YYYY DD/MM/YYYY YYYY/MM/DD YYYY-MM-DD DD-MM-YYYY YYYY.MM.DD DD.MM.YYYY].freeze

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

  ARCHIVED_SUFFIX = / \(archived \d{4}-\d{2}-\d{2}\)\z/

  # Returns the stripped name, or nil when it is not a string, is blank,
  # contains control characters (including NUL), or is too long.
  def self.clean_name(raw)
    return nil unless raw.is_a?(String)

    name = raw.strip
    return nil if name.empty? || name.length > MAX_NAME_LENGTH || name.match?(/[[:cntrl:]]/)

    name
  end

  # Name for an archived plan: "<base> (archived YYYY-MM-DD)". An existing
  # archive suffix is replaced, not nested, and the base is shortened if
  # needed so the result always fits MAX_NAME_LENGTH and can be saved again.
  # The date is the server's current date (Rails time zone), not the
  # user's; per-user time zones are not modeled.
  def self.archived_name(name, on: Date.current)
    suffix = " (archived #{on.iso8601})"
    base = name.sub(ARCHIVED_SUFFIX, "")
    "#{base[0, MAX_NAME_LENGTH - suffix.length].rstrip}#{suffix}"
  end

  # Scheduled transactions that cannot be carried as they are because they
  # point at an account or category the new plan will not contain (deleted
  # accounts, deleted, internal or card-payment categories, split lines that
  # transfer to a deleted account). Closed accounts DO carry, still closed.
  # Fresh Start refuses to run while any exist, so meaning never changes
  # silently.
  # Returns [{ id: scheduled public_id, reasons: [...] }].
  def self.carry_blockers(original)
    open_accounts = original.accounts.not_deleted.pluck(:id).to_set
    carried_categories = original.categories.not_deleted.where(internal: false, payment_account_id: nil)
      .joins(:category_group).merge(CategoryGroup.where(deleted: false, internal: false)
      .where.not(name: Budget::CREDIT_CARD_PAYMENTS_GROUP_NAME)).pluck(:id).to_set
    # Credit card payment categories of carried accounts are remapped to the
    # new plan's own payment categories.
    carried_categories.merge(original.categories.not_deleted.where(payment_account_id: open_accounts.to_a).pluck(:id))
    original.scheduled_transactions.not_deleted.order(:id).filter_map do |scheduled|
      reasons = []
      reasons << "its account is deleted" unless open_accounts.include?(scheduled.account_id)
      if scheduled.transfer_account_id && !open_accounts.include?(scheduled.transfer_account_id)
        reasons << "it transfers to a deleted account"
      end
      if scheduled.category_id && !carried_categories.include?(scheduled.category_id)
        reasons << "its category is deleted or internal"
      end
      scheduled.scheduled_sub_transactions.where(deleted: false).each do |sub|
        if sub.transfer_account_id && !open_accounts.include?(sub.transfer_account_id)
          reasons << "a split line transfers to a deleted account"
        end
        if sub.category_id && !carried_categories.include?(sub.category_id)
          reasons << "a split line uses a deleted category"
        end
      end
      { id: scheduled.public_id, reasons: reasons.uniq } if reasons.any?
    end
  end

  # What a Fresh Start of this plan carries and leaves behind.
  def self.carry_report(original)
    {
      open_accounts_carried: original.accounts.not_deleted.where(closed: false).count,
      closed_accounts_carried_closed: original.accounts.not_deleted.where(closed: true).count,
      scheduled_transactions_carried: original.scheduled_transactions.not_deleted.count
    }
  end

  class UnsupportedCarry < StandardError
    attr_reader :blockers

    def initialize(blockers)
      @blockers = blockers
      super("Fresh Start cannot carry #{blockers.size} scheduled transaction(s) unchanged.")
    end
  end

  # Fresh Start: the original plan keeps its identity, history and balances
  # under an archived name. A new plan takes the original name with the same
  # formats, categories and groups (including targets), all accounts (closed
  # ones stay closed) at zero with no transactions, and scheduled
  # transactions. Posted
  # transactions, assignments and balances do not carry.
  def self.fresh_start(original, name: nil)
    Budget.transaction do
      blockers = carry_blockers(original)
      raise UnsupportedCarry, blockers if blockers.any?

      new_name = name.presence || original.name.sub(ARCHIVED_SUFFIX, "")
      original.update!(name: archived_name(original.name))
      fresh = original.user.budgets.create!(name: new_name, date_format: original.date_format,
        currency_format: original[:currency_format])
      account_map = copy_accounts(original, fresh)
      category_map = copy_categories(original, fresh)
      map_payment_categories(original, fresh, account_map, category_map)
      copy_scheduled_transactions(original, fresh, account_map, category_map)
      fresh
    end
  end

  def self.copy_accounts(original, fresh)
    original.accounts.not_deleted.order(:id).each_with_object({}) do |account, map|
      # Account.open! gives each account its zero Starting Balance row dated
      # today (as the reference does); no other history carries.
      copy = Account.open!(budget: fresh, attributes: { "name" => account.name, "type" => account.type, "balance" => 0 })
      copy.update!(on_budget: account.on_budget, note: account.note, closed: account.closed)
      map[account.id] = copy.id
    end
  end

  # A card's Credit Card Payment category is created with the card account in
  # the new plan; schedules that pay the card point at that new category.
  def self.map_payment_categories(original, fresh, account_map, category_map)
    original.categories.not_deleted.where.not(payment_account_id: nil).each do |old|
      new_account_id = account_map[old.payment_account_id]
      new_category = new_account_id && fresh.categories.not_deleted.find_by(payment_account_id: new_account_id)
      category_map[old.id] = new_category.id if new_category
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
      account_id = account_map.fetch(scheduled.account_id)
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
  private_class_method :copy_accounts, :copy_categories, :map_payment_categories, :copy_scheduled_transactions
end
