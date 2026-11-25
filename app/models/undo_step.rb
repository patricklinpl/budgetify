class UndoStep < ApplicationRecord
  belongs_to :budget
  belongs_to :user

  KINDS = %w[create edit delete].freeze
  validates :kind, inclusion: { in: KINDS }

  def before = JSON.parse(before_json)
  def after = JSON.parse(after_json)
end
