require "securerandom"

class Payee < ApplicationRecord
  belongs_to :budget
  belongs_to :transfer_account, class_name: "Account", optional: true, inverse_of: :transfer_payee
  has_many :payee_locations, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :name, presence: true, length: { maximum: 500 }
  validate :name_is_unique_within_plan, unless: :transfer_payee?

  # Transfer payees are auto-created per account and managed through the
  # account; the API treats them as read-only (spec: renaming one is a 400).
  def transfer_payee?
    transfer_account_id.present?
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end

    # Duplicate payee names within a plan are rejected (case-insensitive);
    # soft-deleted payees do not block reuse.
    def name_is_unique_within_plan
      return if name.blank?

      clash = budget.payees.not_deleted.where.not(id: id).where("LOWER(name) = ?", name.downcase)
      errors.add(:name, "has already been taken") if clash.exists?
    end
end
