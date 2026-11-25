require "securerandom"

class ScheduledTransaction < ApplicationRecord
  # YNAB scheduled transaction frequencies (spec:
  # ScheduledTransactionFrequency).
  FREQUENCIES = %w[
    never daily weekly everyOtherWeek twiceAMonth every4Weeks monthly
    everyOtherMonth every3Months every4Months twiceAYear yearly everyOtherYear
  ].freeze
  FLAG_COLORS = Transaction::FLAG_COLORS

  belongs_to :budget
  belongs_to :account
  belongs_to :payee, optional: true
  belongs_to :category, optional: true
  belongs_to :transfer_account, class_name: "Account", optional: true
  has_many :scheduled_sub_transactions, -> { order(:created_at) }, dependent: :destroy, inverse_of: :scheduled_transaction

  scope :not_deleted, -> { where(deleted: false) }

  before_validation :assign_public_id, on: :create
  before_save :assign_knowledge

  validates :date_first, :date_next, presence: true
  validates :memo, length: { maximum: 500 }
  validates :frequency, inclusion: { in: FREQUENCIES }
  validates :flag_color, inclusion: { in: FLAG_COLORS }, allow_nil: true

  # Anchored occurrences preserve month-end intent (Jan 31 -> Feb 28 ->
  # Mar 31). Twice-monthly alternates the anchor day and 15 days later,
  # not a drifting every-15-days cadence. YNAB Scheduled Transactions guide.
  def self.occurrence(first, frequency, index)
    days = { "daily" => 1, "weekly" => 7, "everyOtherWeek" => 14, "every4Weeks" => 28 }
    return first + days.fetch(frequency) * index if days.key?(frequency)
    return first.advance(months: index / 2) + (index.odd? ? 15 : 0) if frequency == "twiceAMonth"

    months = { "monthly" => 1, "everyOtherMonth" => 2, "every3Months" => 3, "every4Months" => 4, "twiceAYear" => 6, "yearly" => 12, "everyOtherYear" => 24 }
    return first.advance(months: months.fetch(frequency) * index) if months.key?(frequency)
    first
  end

  # Next date after a twiceAMonth schedule's current date_next, as the YNAB
  # reference advances it when an occurrence is entered (SCHED-03 vectors,
  # observed 2026-11-23). On or before the 15th the next date is 15 days
  # later, held to the month end (Feb 15 -> Feb 28). After the 15th it is the
  # day minus 15 in the following month (Dec 16 -> Jan 1, Dec 31 -> Jan 16).
  # This steps from the current date and does not use the anchored
  # occurrence() cadence above; the two differ for first dates after the 15th.
  def self.next_twice_a_month(date)
    return date + 15 if date.day <= 15 && (date + 15).month == date.month
    return date.end_of_month if date.day <= 15

    (date.beginning_of_month.next_month) + (date.day - 16)
  end

  def recompute_date_next!
    return if date_first.nil?

    self.date_next = date_first
    return unless FREQUENCIES.include?(frequency) && frequency != "never"

    index = 0
    while date_next < Date.current
      index += 1
      self.date_next = self.class.occurrence(date_first, frequency, index)
    end
  end

  private
    def assign_public_id
      self.public_id ||= SecureRandom.uuid
    end

    # Stamps this record with the plan's next knowledge value so delta
    # requests on scheduled-transaction lists return it (spec:
    # last_knowledge_of_server).
    def assign_knowledge
      self.knowledge = budget.next_knowledge!
    end
end
