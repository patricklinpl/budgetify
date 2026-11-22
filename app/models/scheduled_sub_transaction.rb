require "securerandom"

class ScheduledSubTransaction < ApplicationRecord
  belongs_to :scheduled_transaction, inverse_of: :scheduled_sub_transactions
  belongs_to :payee, optional: true
  belongs_to :category, optional: true
  belongs_to :transfer_account, class_name: "Account", optional: true

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end
end
