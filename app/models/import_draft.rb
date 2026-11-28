require "securerandom"

# The CSV text and settings of one previewed import, so confirming reads the
# file the user saw. [engineering] My choice: stored server side for one day (a
# file can be 5 MB, too large for a cookie or a form field), then purged.
class ImportDraft < ApplicationRecord
  belongs_to :budget
  belongs_to :account
  belongs_to :user

  STALE_AFTER = 1.day
  PURGE_BATCH = 200

  before_validation { self.token ||= SecureRandom.hex(16) }

  def self.purge_stale!(now: Time.current)
    ids = where(created_at: ...(now - STALE_AFTER)).limit(PURGE_BATCH).pluck(:id)
    where(id: ids).delete_all
  end

  def settings = JSON.parse(settings_json).symbolize_keys.tap do |s|
    s[:date_format] = s[:date_format].to_sym
    s[:amount_format] = s[:amount_format].to_sym
  end
end
