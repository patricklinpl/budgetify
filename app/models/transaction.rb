require "securerandom"

class Transaction < ApplicationRecord
  # YNAB cleared statuses (spec: TransactionClearedStatus).
  CLEARED_STATUSES = %w[cleared uncleared reconciled].freeze
  # YNAB flag colors (spec: TransactionFlagColor; "" means unflagged).
  FLAG_COLORS = %w[red orange yellow green blue purple].freeze

  belongs_to :budget
  belongs_to :account
  belongs_to :payee, optional: true
  belongs_to :category, optional: true
  belongs_to :transfer_account, class_name: "Account", optional: true
  belongs_to :transfer_transaction, class_name: "Transaction", optional: true
  belongs_to :matched_transaction, class_name: "Transaction", optional: true
  has_many :sub_transactions, -> { order(:created_at) }, dependent: :destroy, inverse_of: :parent_transaction

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :date, presence: true
  validates :cleared, inclusion: { in: CLEARED_STATUSES }
  validates :flag_color, inclusion: { in: FLAG_COLORS }, allow_nil: true

  # The plan month (first of month) this transaction belongs to (spec:
  # month scoping on plan-month transaction lists).
  def month
    date&.beginning_of_month
  end

  # Adjusts the account balance and the category's month activity for this
  # transaction by the given sign (+1 applies, -1 reverses). Cleared and
  # reconciled transactions count toward the cleared balance; uncleared
  # ones toward the uncleared balance (spec: Account balances). Category
  # activity feeds the month's rollup (spec: MonthSummary.activity and
  # MonthSummary.income via the internal Inflow category).
  def apply_amounts!(sign)
    delta = amount.to_i * sign
    account.balance += delta
    if cleared == "uncleared"
      account.uncleared_balance += delta
    else
      account.cleared_balance += delta
    end
    account.save!

    # Credit-account activity (spending or a payment transfer in) changes
    # the card's derived Credit Card Payment category, so its knowledge is
    # stamped for delta requests on category lists.
    budget.categories.not_deleted.where.not(payment_account_id: nil).find_each do |payment_category|
      payment_category.update_column(:knowledge, budget.next_knowledge!)
    end

    return if category.nil? || sub_transactions.exists?

    month_category = category.month_categories.find_or_initialize_by(month: month)
    month_category.activity = month_category.activity.to_i + delta
    month_category.credit_activity = month_category.credit_activity.to_i + delta if account.credit?
    month_category.save!
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on transaction lists return it (spec:
    # last_knowledge_of_server).
    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
