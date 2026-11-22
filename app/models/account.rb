require "securerandom"

class Account < ApplicationRecord
  # The `type` column is a YNAB API field name (spec: Account.type), not
  # Rails single-table inheritance.
  self.inheritance_column = :_type_disabled

  # YNAB account types (spec: AccountType enum in responses).
  TYPES = %w[checking savings cash creditCard lineOfCredit otherAsset otherLiability mortgage autoLoan studentLoan personalLoan medicalDebt otherDebt].freeze
  # Types accepted when creating an account (spec: SaveAccountType enum).
  SAVE_TYPES = %w[checking savings cash creditCard otherAsset otherLiability].freeze

  belongs_to :budget
  has_one :transfer_payee, -> { where(deleted: false) }, class_name: "Payee",
    foreign_key: :transfer_account_id, inverse_of: :transfer_account, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge
  after_create :create_transfer_payee
  after_update :sync_transfer_payee_name, if: :saved_change_to_name?

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  private
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
