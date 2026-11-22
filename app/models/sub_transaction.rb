require "securerandom"

class SubTransaction < ApplicationRecord
  belongs_to :parent_transaction, class_name: "Transaction", foreign_key: "transaction_id", inverse_of: :sub_transactions
  belongs_to :payee, optional: true
  belongs_to :category, optional: true
  belongs_to :transfer_account, class_name: "Account", optional: true

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :amount, presence: true

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this subtransaction with the plan's next knowledge value so
    # delta requests on hybrid lists surface sub-only changes (spec:
    # last_knowledge_of_server).
    def assign_knowledge
      self.knowledge = parent_transaction.budget.next_knowledge!
    end
end
