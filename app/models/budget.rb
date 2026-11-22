require "securerandom"

class Budget < ApplicationRecord
  belongs_to :user
  has_many :accounts, dependent: :destroy
  has_many :payees, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge
  validates :name, presence: true

  # The next knowledge value for this plan's resources. YNAB delta requests
  # under /v1/plans/{plan_id}/... are evaluated against this counter;
  # child entities stamp their knowledge from it.
  def next_knowledge!
    increment!(:server_knowledge)
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
end
