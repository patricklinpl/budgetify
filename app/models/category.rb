require "securerandom"

class Category < ApplicationRecord
  # YNAB goal types (spec: Category.goal_type enum).
  GOAL_TYPES = %w[TB TBD MF NEED DEBT].freeze

  belongs_to :budget
  belongs_to :category_group
  # Set on system-managed Credit Card Payment categories: the credit
  # account whose payments this category funds (YNAB docs: Credit Card
  # Payments guide). Nil on ordinary categories.
  belongs_to :payment_account, class_name: "Account", optional: true, inverse_of: :payment_category
  has_many :month_categories, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :name, presence: true
  validates :goal_type, inclusion: { in: GOAL_TYPES }, allow_nil: true

  # Credit Card Payment categories hold no categorized transactions
  # (spec: SaveTransaction.category_id); their activity is derived from
  # funded credit spending and payments (CreditCardFunding).
  def payment?
    payment_account_id.present?
  end

  # The per-month amounts record for a plan month (unsaved when the month
  # has no explicit assignment yet; spec: amounts are per plan month).
  def month_category_for(month)
    month_categories.find_by(month: month) || month_categories.build(month: month)
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the categories list return it (including tombstones)
    # for later last_knowledge_of_server values.
    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
