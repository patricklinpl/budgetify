require "securerandom"

class Payee < ApplicationRecord
  # Payee names may contain only letters, numbers and spaces (spec:
  # SavePayee docs). Transfer payees are exempt: their auto-generated
  # "Transfer : <account>" names contain punctuation.
  NAME_FORMAT = /\A[\p{L}\p{N} ]+\z/

  # The register editor accepts any payee name, as the reference app does. The
  # API keeps the letters, numbers and spaces rule (SavePayee docs).
  attr_accessor :allow_any_name

  belongs_to :budget
  belongs_to :transfer_account, class_name: "Account", optional: true, inverse_of: :transfer_payee
  has_many :payee_locations, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :name, presence: true, length: { maximum: 500 }
  validates :name, format: { with: NAME_FORMAT, message: "may only contain letters, numbers and spaces" }, unless: -> { transfer_payee? || allow_any_name }
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
