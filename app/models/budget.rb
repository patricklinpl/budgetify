require "securerandom"

class Budget < ApplicationRecord
  belongs_to :user

  before_validation :assign_public_id, on: :create
  validates :name, presence: true

  private

  def assign_public_id
    self.public_id ||= SecureRandom.uuid
  end
end
