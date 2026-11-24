require "securerandom"

class Account < ApplicationRecord
  # The `type` column is a YNAB API field name (spec: Account.type), not
  # Rails single-table inheritance.
  self.inheritance_column = :_type_disabled

  # YNAB account types (spec: AccountType enum in responses).
  TYPES = %w[checking savings cash creditCard lineOfCredit otherAsset otherLiability mortgage autoLoan studentLoan personalLoan medicalDebt otherDebt].freeze
  # Types accepted when creating an account (spec: SaveAccountType enum).
  SAVE_TYPES = %w[checking savings cash creditCard lineOfCredit otherAsset otherLiability].freeze
  # Types whose spending is credit-backed: overspending from these accounts
  # carries as category debt instead of reducing next month's Ready to
  # Assign (spec: AccountType).
  CREDIT_TYPES = %w[creditCard lineOfCredit].freeze

  belongs_to :budget
  has_many :transactions, dependent: :destroy
  has_one :transfer_payee, -> { where(deleted: false) }, class_name: "Payee",
    foreign_key: :transfer_account_id, inverse_of: :transfer_account, dependent: :destroy
  # The system-managed Credit Card Payment category funding this card's
  # payments (credit accounts only; YNAB docs: Credit Card Payments guide).
  has_one :payment_category, class_name: "Category", foreign_key: :payment_account_id, inverse_of: :payment_account

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge
  after_create :create_transfer_payee
  after_update :sync_transfer_payee_name, if: :saved_change_to_name?
  after_create :create_payment_category, if: :credit?
  after_update :sync_payment_category_name, if: -> { credit? && saved_change_to_name? }

  validates :name, presence: true

  # Account POST records starting funds in the ledger atomically. Model
  # fixtures/imports can still create raw accounts without inventing
  # historical transactions. Existing records are not backfilled here.
  def self.open!(budget:, attributes:)
    transaction do
      amount = attributes.fetch("balance")
      account = budget.accounts.create!(
        name: attributes["name"], type: attributes["type"],
        on_budget: !%w[otherAsset otherLiability].include?(attributes["type"])
      )
      payee = budget.payees.not_deleted.where("LOWER(name) = ?", "starting balance").first ||
        budget.payees.create!(name: "Starting Balance")
      # The marked transaction selects its category on every validation,
      # including later amount edits across zero.
      opening = budget.transactions.create!(account: account, payee: payee,
        date: Date.current, amount: amount,
        cleared: "cleared", approved: true, opening_balance: true)
      opening.apply_amounts!(+1)
      account.reload
    end
  end

  ADJUSTMENT_PAYEE_NAME = "Manual Balance Adjustment".freeze

  class Blocked < StandardError; end

  # Tracking (off-budget) accounts are the only ones with a tested
  # adjustment/close reference (TRACK-01, TRACK-02). On-budget behavior
  # for these actions is untested, so it is refused rather than guessed.
  def tracking?
    !on_budget?
  end

  # Records an auditable, category-less Manual Balance Adjustment so the
  # balance equals target without rewriting history.
  def adjust_balance!(target)
    raise Blocked, "Only tracking accounts can have their balance adjusted here." unless tracking?
    raise Blocked, "This account is closed. Reopen it before changing its balance." if closed?
    delta = target - balance
    return nil if delta.zero?

    transaction do
      payee = budget.payees.not_deleted.where("LOWER(name) = ?", ADJUSTMENT_PAYEE_NAME.downcase).first ||
        budget.payees.create!(name: ADJUSTMENT_PAYEE_NAME)
      entry = budget.transactions.create!(account: self, payee: payee, date: Date.current,
        amount: delta, cleared: "cleared", approved: true, memo: ADJUSTMENT_PAYEE_NAME)
      entry.apply_amounts!(+1)
      entry
    end
  end

  RECONCILIATION_PAYEE_NAME = "Reconciliation Balance Adjustment".freeze
  # Wording is Budgetify's own; the audit (#63 REC-02) only says the memo is automatic.
  RECONCILIATION_MEMO = "Entered automatically by Budgetify".freeze

  Reconciliation = Struct.new(:marked, :adjustment, :difference)

  # Reconcile (#63 REC-01 to REC-03). Every cleared row becomes reconciled;
  # uncleared rows stay as they are and balances do not change by this step.
  # With an entered statement balance that differs from the cleared balance, one
  # adjustment is recorded for the difference, already reconciled, dated today,
  # in the Ready to Assign category for a cash account (#63 REC-02; confirmed in the
  # reference test account for both directions). Tracking accounts and credit
  # cards leave Ready to Assign alone; a card with a positive balance is
  # untested in the reference and is treated like debt here. A split counts once, through its parent. Nothing is
  # written unless the whole step succeeds.
  def reconcile!(entered: nil)
    raise Blocked, "This account is closed. Reopen it before reconciling." if closed?

    transaction do
      current = self.class.lock.find(id)
      difference = entered.nil? ? 0 : entered - current.cleared_balance
      rows = budget.transactions.not_deleted.where(account_id: id, cleared: "cleared").to_a
      rows.each { |row| row.update!(cleared: "reconciled") }

      adjustment = nil
      unless difference.zero?
        payee = budget.payees.not_deleted.where("LOWER(name) = ?", RECONCILIATION_PAYEE_NAME.downcase).first ||
          budget.payees.create!(name: RECONCILIATION_PAYEE_NAME)
        adjustment = budget.transactions.create!(account: self, payee: payee, date: Date.current, amount: difference,
          cleared: "reconciled", approved: true, memo: RECONCILIATION_MEMO,
          category: (budget.categories.not_deleted.find_by!(internal: true, name: Budget::INFLOW_CATEGORY_NAME) if reconciliation_moves_ready_to_assign?))
        adjustment.apply_amounts!(+1)
      end
      reload
      Reconciliation.new(rows.size, adjustment, difference)
    end
  end

  def reconciliation_moves_ready_to_assign?
    on_budget? && !credit?
  end

  # Close zeroes a tracking balance with an adjustment and keeps history.
  def close!
    raise Blocked, "Only tracking accounts with a nonzero balance can be closed with a zeroing adjustment; this account is on budget." if !tracking? && !balance.zero?
    transaction do
      adjust_balance!(0) if tracking?
      update!(closed: true)
    end
    self
  end

  # Reopening returns the account at 0, not its pre-close balance.
  def reopen!
    update!(closed: false)
    self
  end

  # Why this account cannot be deleted, or nil when it can. Deletable only
  # when its sole activity is its opening balance and no budget money sits on
  # its payment category (deleting would otherwise drop assignments silently).
  def delete_blocker
    live = transactions.not_deleted.to_a
    unless live.size == 1 && live.first.opening_balance? && live.first.transfer_account_id.nil? &&
        !Transaction.not_deleted.where(transfer_account_id: id).exists? &&
        !ScheduledTransaction.where(deleted: false).where("account_id = ? OR transfer_account_id = ?", id, id).exists?
      return "This account has transactions, transfers or scheduled items. Remove them before deleting it."
    end

    category = Category.not_deleted.find_by(payment_account_id: id)
    if category && category.month_categories.where("budgeted <> 0 OR activity <> 0 OR credit_activity <> 0").exists?
      return "Its payment category has money assigned or activity. Move or remove that first so no budget money is lost."
    end
    nil
  end

  def deletable?
    delete_blocker.nil?
  end

  def delete_opening_only!
    reason = delete_blocker
    raise Blocked, reason if reason
    transaction do
      opening = transactions.not_deleted.sole
      opening.apply_amounts!(-1)
      opening.update!(deleted: true)
      Category.not_deleted.where(payment_account_id: id).find_each { |c| c.update!(deleted: true) }
      Payee.not_deleted.where(transfer_account_id: id).find_each { |p| p.update!(deleted: true) }
      update!(deleted: true)
    end
    self
  end

  def credit?
    CREDIT_TYPES.include?(type)
  end

  # Creates (or returns) this credit account's Credit Card Payment
  # category under the plan's "Credit Card Payments" group. YNAB names
  # the category after the account and keeps them paired (YNAB docs:
  # Credit Card Payments guide).
  def ensure_payment_category!
    existing = Category.not_deleted.find_by(payment_account_id: id)
    return existing if existing

    group = budget.category_groups.not_deleted.where(name: Budget::CREDIT_CARD_PAYMENTS_GROUP_NAME).first_or_create!
    group.categories.create!(budget: budget, name: name, payment_account_id: id)
  end
  validates :type, inclusion: { in: TYPES }

  private
    def create_payment_category
      ensure_payment_category!
    end

    def sync_payment_category_name
      Category.not_deleted.where(payment_account_id: id).each { |category| category.update!(name: name) }
    end

    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the accounts list return it (including tombstones) for
    # later last_knowledge_of_server values (spec: delta requests).
    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end

    # YNAB auto-creates a transfer payee for each account; transfers to the
    # account use that payee's id (spec: Account.transfer_payee_id).
    def create_transfer_payee
      budget.payees.create!(name: "Transfer : #{name}", transfer_account: self)
    end

    # Keeps the auto-created transfer payee's name in sync when the account
    # is renamed (issue #30: transfer payees track their account's name).
    def sync_transfer_payee_name
      transfer_payee&.update!(name: "Transfer : #{name}")
    end
end
