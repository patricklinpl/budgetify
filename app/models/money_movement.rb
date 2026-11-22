require "securerandom"

class MoneyMovement < ApplicationRecord
  belongs_to :budget
  belongs_to :money_movement_group, optional: true
  belongs_to :performed_by_user, class_name: "User", optional: true
  belongs_to :from_category, class_name: "Category", optional: true
  belongs_to :to_category, class_name: "Category", optional: true

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :stamp_knowledge

  validates :month, :amount, presence: true

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the money movements list return it (spec:
    # last_knowledge_of_server).
    def stamp_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
