require "securerandom"

class CategoryGroup < ApplicationRecord
  belongs_to :budget
  has_many :categories, dependent: :destroy

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :name, presence: true, length: { maximum: 50 }

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the categories list return it (including tombstones)
    # for later last_knowledge_of_server values.
    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
