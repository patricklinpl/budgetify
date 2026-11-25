# Enter Now for one scheduled transaction (#61). Scope is what the audit
# observed (SCHED-01, SCHED-BOUNDARY-01/02, [reference T]): a twiceAMonth
# schedule. Entering creates ONE uncleared transaction dated the day of entry,
# with the schedule's signed amount, payee, category and memo, and advances
# the retained schedule to its next date. Both changes, and the Undo step that
# reverses them together, commit or roll back as one.
#
# Not grounded by the audit, so refused rather than guessed ([engineering]
# refusals, not reference behavior): other frequencies' next date, "never"
# schedules, split schedules, a transfer schedule's pair, a schedule that is
# due today or past due (the T vectors are future-dated only), and automatic
# entry (SCHED-04, [P/U]).
class ScheduledEntry
  class Unsupported < StandardError; end

  FREQUENCY = "twiceAMonth".freeze

  def initialize(plan, history: nil)
    @plan = plan
    @history = history
  end

  # Returns the created transaction.
  def enter_now!(scheduled, on: Date.current)
    ScheduledTransaction.transaction do
      # lock! reloads the row, so every eligibility check below judges the
      # locked database state, not a copy the caller loaded earlier.
      scheduled.lock!
      check_supported!(scheduled, on)
      before_sched = sched_image(scheduled)
      writer = TransactionWriter.new(@plan)
      transaction = writer.persist_new!(writer.build(attributes(scheduled, on)))
      scheduled.update!(date_next: ScheduledTransaction.next_twice_a_month(scheduled.date_next))
      record!(transaction, scheduled, before_sched)
      transaction
    end
  rescue StandardError
    # A rollback does not restore the in-memory attributes of a record updated
    # inside the block; reload so the caller never holds the advanced date.
    scheduled.reload if scheduled.persisted?
    raise
  end

  private
    def check_supported!(scheduled, on)
      raise Unsupported, "That scheduled transaction is not in this plan." unless scheduled.budget_id == @plan.id && !scheduled.deleted
      raise Unsupported, "Only twice-a-month schedules can be entered yet." unless scheduled.frequency == FREQUENCY
      raise Unsupported, "Split scheduled transactions cannot be entered yet." if scheduled.scheduled_sub_transactions.not_deleted.exists?
      raise Unsupported, "Transfer schedules cannot be entered yet." if scheduled.transfer_account_id
      raise Unsupported, "Only schedules dated after today can be entered yet." unless scheduled.date_next > on
    end

    def attributes(scheduled, on)
      {
        "account_id" => scheduled.account.public_id, "date" => on.iso8601, "amount" => scheduled.amount,
        "memo" => scheduled.memo, "cleared" => "uncleared", "payee_id" => scheduled.payee&.public_id,
        "category_id" => scheduled.category&.public_id, "flag_color" => scheduled.flag_color
      }.compact
    end

    def sched_image(scheduled) = { scheduled.id.to_s => scheduled.attributes.slice(*UndoSnapshot::SCHED_FIELDS).as_json }

    def record!(transaction, scheduled, before_sched)
      return if @history.nil?

      ids = UndoSnapshot.reachable(transaction)
      after = UndoSnapshot.take(@plan, ids).merge("sched" => sched_image(scheduled.reload))
      before = UndoSnapshot.blank_new_rows(UndoSnapshot.take(@plan, UndoSnapshot::Ids.new([], [])), after).merge("sched" => before_sched)
      @history.record!(kind: :enter, before: before, after: after)
    end
end
