require "securerandom"

class PayeeLocation < ApplicationRecord
  belongs_to :payee

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :latitude, :longitude, presence: true

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on the payee locations list return it (including
    # tombstones) for later last_knowledge_of_server values.
    def assign_knowledge
      self.knowledge = payee.budget.next_knowledge!
    end
end
