require "securerandom"

class Budget < ApplicationRecord
  belongs_to :user
  has_many :accounts, dependent: :destroy
  has_many :payees, dependent: :destroy
  has_many :category_groups, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :money_movements, dependent: :destroy
  has_many :money_movement_groups, dependent: :destroy
  has_many :transactions, dependent: :destroy
  has_many :scheduled_transactions, dependent: :destroy

  # YNAB's built-in internal group/category: the "Inflow: Ready to Assign"
  # category is internal and not assignable via the API (spec: Category
  # internal flag; issue #29).
  INTERNAL_GROUP_NAME = "Internal Master Category"
  INFLOW_CATEGORY_NAME = "Inflow: Ready to Assign"
  # YNAB's system-managed group holding one Credit Card Payment category
  # per credit account (YNAB docs: Credit Card Payments guide).
  CREDIT_CARD_PAYMENTS_GROUP_NAME = "Credit Card Payments"

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge
  after_create :create_internal_category_group
  validates :name, presence: true

  # The next knowledge value for this plan's resources. YNAB delta requests
  # under /v1/plans/{plan_id}/... are evaluated against this counter;
  # child entities stamp their knowledge from it.
  def next_knowledge!
    increment!(:server_knowledge)
    # A child write is also a plan change. Keep both summary metadata
    # and the documented plans-list delta extension current. Reads use
    # update_column(:last_used_at) and do not call this method.
    update_columns(updated_at: Time.current, knowledge: user.next_server_knowledge!)
    server_knowledge
  end

  # The plan's persisted currency format (spec: CurrencyFormat schema).
  # Falls back to the USD default when none is stored; settings become
  # user-editable with a later issue.
  def currency_format
    stored = self[:currency_format]
    return CurrencyFormat.default if stored.blank?

    CurrencyFormat.new(**stored.symbolize_keys)
  end

  # The same month range is used by summaries and the month endpoints.
  # Historical transactions/assignments can predate plan creation.
  def first_month
    assigned = MonthCategory.joins(:category).where(categories: { budget_id: id }).minimum(:month)
    earliest_transaction = transactions.not_deleted.minimum(:date)&.beginning_of_month
    [ created_at.to_date.beginning_of_month, assigned, earliest_transaction, Date.current.beginning_of_month ].compact.min
  end

  def last_month
    Date.current.beginning_of_month
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the user's next global knowledge value so
    # delta requests on the plans list return it (including tombstones)
    # for later last_knowledge_of_server values.
    def assign_knowledge
      self.knowledge = user.next_server_knowledge!
    end

    # Creates the plan's built-in internal category group and its "Inflow:
    # Ready to Assign" category (spec: internal categories).
    def create_internal_category_group
      group = category_groups.create!(name: INTERNAL_GROUP_NAME, internal: true, hidden: true)
      group.categories.create!(budget: self, name: INFLOW_CATEGORY_NAME, internal: true, hidden: true)
    end
end
