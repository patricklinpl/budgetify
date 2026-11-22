require "securerandom"

class MoneyMovementGroup < ApplicationRecord
  belongs_to :budget
  belongs_to :performed_by_user, class_name: "User", optional: true
  has_many :money_movements, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :stamp_knowledge

  validates :group_created_at, :month, presence: true

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the money movement groups list return it (spec:
    # last_knowledge_of_server).
    def stamp_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
