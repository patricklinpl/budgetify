require "securerandom"

class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :budgets, dependent: :destroy

  normalizes :email_address, with: ->(email) { email.strip.downcase }
  before_validation :assign_public_id, on: :create

  validates :email_address, presence: true, uniqueness: true

  # The next value of the user's global knowledge counter. YNAB delta
  # requests (last_knowledge_of_server) on the plans list are evaluated
  # against this counter.
  def next_server_knowledge!
    increment!(:server_knowledge)
    server_knowledge
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end
end
