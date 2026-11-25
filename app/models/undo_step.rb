class UndoStep < ApplicationRecord
  belongs_to :budget
  belongs_to :user

  KINDS = %w[create edit delete enter reset].freeze
  validates :kind, inclusion: { in: KINDS }

  STALE_AFTER = 1.day
  PURGE_BATCH = 500

  # Spec revision 3: stale sessions are purged by age. Bounded: at most one
  # batch per call, so a page load never runs an unbounded delete.
  def self.purge_stale!(now: Time.current)
    ids = where(created_at: ...(now - STALE_AFTER)).limit(PURGE_BATCH).pluck(:id)
    where(id: ids).delete_all
  end

  def before = JSON.parse(before_json)
  def after = JSON.parse(after_json)
end
