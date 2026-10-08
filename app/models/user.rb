require "securerandom"

class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(email) { email.strip.downcase }
  before_validation :assign_public_id, on: :create

  validates :email_address, presence: true, uniqueness: true

  private

  def assign_public_id
    self.public_id ||= SecureRandom.uuid
  end
end
