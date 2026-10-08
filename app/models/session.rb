require "digest"
require "securerandom"

class Session < ApplicationRecord
  belongs_to :user

  def self.authenticate_api_token(token)
    find_by(api_token_digest: api_token_digest(token))
  end

  def self.api_token_digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def generate_api_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(api_token_digest: self.class.api_token_digest(token))
    token
  end
end
