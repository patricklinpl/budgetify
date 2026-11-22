require "securerandom"

class Payee < ApplicationRecord
  belongs_to :budget
  belongs_to :transfer_account, class_name: "Account", optional: true, inverse_of: :transfer_payee

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge
  validates :name, presence: true

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
