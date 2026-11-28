# Server-side Undo and Redo for one user, plan, session and page-load token
# (Undo slice 1, engineering decisions in the spec of record, revision 3).
#
# The stack lives in undo_steps, not the cookie session, so a step can hold
# split snapshots. Recording and applying run inside the caller's database
# transaction: data and stack commit or roll back together.
class UndoHistory
  MAX_STEPS = 50
  MAX_STEP_BYTES = 64 * 1024
  STALE = "Nothing was changed: the transaction was edited or reconciled after that step, so it cannot be applied safely.".freeze
  CLEARED = "Undo history was cleared because that change cannot be undone.".freeze

  class Refused < StandardError; end

  attr_reader :notice

  def initialize(user:, budget:, session_key:, token:)
    @user = user
    @budget = budget
    @session_key = session_key.to_s
    @token = token.to_s
  end

  def steps = UndoStep.where(user: @user, budget: @budget, session_key: @session_key, token: @token)
  def can_undo? = steps.where(undone: false).exists?
  def can_redo? = steps.where(undone: true).exists?

  # A recorded step drops the redo steps. A step over the size cap is never
  # truncated: it is not recorded and the whole history is cleared, so an older
  # step is never offered as the latest. Returns true when recorded.
  def record!(kind:, before:, after:, max_bytes: MAX_STEP_BYTES)
    before_json = JSON.generate(before)
    after_json = JSON.generate(after)
    bytes = before_json.bytesize + after_json.bytesize
    return clear_all! if bytes > max_bytes

    UndoStep.transaction do
      steps.where(undone: true).delete_all
      position = steps.maximum(:position).to_i + 1
      UndoStep.create!(user: @user, budget: @budget, session_key: @session_key, token: @token, position: position,
        kind: kind.to_s, before_json: before_json, after_json: after_json, byte_size: bytes)
      excess = steps.count - MAX_STEPS
      steps.order(:position).limit(excess).delete_all if excess.positive?
    end
    true
  end

  def clear_all!
    steps.delete_all
    @notice = CLEARED
    false
  end

  def undo!
    step = steps.where(undone: false).order(position: :desc).first
    raise Refused, "There is nothing to undo." if step.nil?

    apply!(step, from: step.after, to: step.before, undone: true)
    "Undid #{label(step)}."
  end

  def redo!
    step = steps.where(undone: true).order(:position).first
    raise Refused, "There is nothing to redo." if step.nil?

    apply!(step, from: step.before, to: step.after, undone: false)
    "Redid #{label(step)}."
  end

  private
    def label(step)
      { "create" => "adding the transaction", "edit" => "the transaction edit", "delete" => "deleting the transaction", "enter" => "entering the scheduled transaction", "reset" => "resetting the available amount", "import" => "the file import" }.fetch(step.kind)
    end

    def apply!(step, from:, to:, undone:)
      writer = TransactionWriter.new(@budget)
      Transaction.transaction do
        tx_ids = from["tx"].keys.map(&:to_i)
        sub_ids = from["sub"].keys.map(&:to_i)
        live = @budget.transactions.where(id: tx_ids).lock.index_by(&:id)
        live_subs = SubTransaction.where(id: sub_ids).lock.index_by(&:id)
        live_sched = @budget.scheduled_transactions.where(id: (from["sched"] || {}).keys.map(&:to_i)).lock.index_by(&:id)
        check_current!(from, live, live_subs)
        check_scheduled!(from, live_sched)
        check_reset!(from)
        check_accounts!(to)

        live.values.reject(&:deleted).each { |transaction| writer.effects!(transaction, -1) }
        restore!(to, live, live_subs)
        restore_scheduled!(to, live_sched)
        restore_reset!(to)
        @budget.transactions.where(id: tx_ids, deleted: false).find_each { |transaction| writer.effects!(transaction, +1) }
        step.update!(undone: undone)
      end
    end

    # Field-level compare of the live rows against the snapshot the step left
    # behind. Any difference (another path, a second tab, a later reconcile)
    # refuses the whole step and changes nothing.
    def check_current!(from, live, live_subs)
      from["tx"].each do |id, attrs|
        row = live[id.to_i]
        if attrs.nil?
          raise Refused, STALE if row && !row.deleted
        else
          raise Refused, STALE if row.nil? || row.attributes.slice(*UndoSnapshot::TX_FIELDS).as_json != attrs
        end
      end
      from["sub"].each do |id, attrs|
        row = live_subs[id.to_i]
        if attrs.nil?
          raise Refused, STALE if row
        elsif row.nil? || row.attributes.slice(*UndoSnapshot::SUB_FIELDS).as_json != attrs
          raise Refused, STALE
        end
      end
    end

    # An Enter Now step also holds the schedule's date_next. The same
    # field-level refusal applies when the schedule changed since.
    def check_scheduled!(from, live_sched)
      (from["sched"] || {}).each do |id, attrs|
        row = live_sched[id.to_i]
        raise Refused, STALE if row.nil? || row.attributes.slice(*UndoSnapshot::SCHED_FIELDS).as_json != attrs
      end
    end

    # A Reset Available step guards every figure it relied on (assigned,
    # activity, carry-forward available, eligibility) in the locked category
    # against the image it starts from (after for Undo, before for Redo), and
    # the plan month must still be the current month. Only assigned is written.
    def check_reset!(from)
      section = from["reset"]
      return if section.nil?

      month = Date.iso8601(section["month"])
      raise Refused, STALE unless month == Date.current.beginning_of_month

      @budget.categories.where(id: section["cat"].keys.map(&:to_i)).lock.to_a
      section["cat"].each do |id, figures|
        category = @budget.categories.find_by(id: id.to_i)
        raise Refused, STALE if category.nil? || UndoSnapshot.reset_image(category, month)["cat"][id] != figures
      end
    end

    # Writes assigned back through the assignment ledger (a new movement row,
    # nothing deleted), then checks the result is the image it restores.
    def restore_reset!(to)
      section = to["reset"]
      return if section.nil?

      month = Date.iso8601(section["month"])
      section["cat"].each do |id, figures|
        category = @budget.categories.find(id.to_i)
        MonthAssignment.set!(budget: @budget, category: category, month: month, amount: figures["assigned"], user: @user)
        raise Refused, STALE unless UndoSnapshot.reset_image(category, month)["cat"][id] == figures
      end
    end

    def restore_scheduled!(to, live_sched)
      (to["sched"] || {}).each { |id, attrs| live_sched.fetch(id.to_i).update!(attrs) }
    end

    def check_accounts!(to)
      ids = to["tx"].values.compact.reject { |attrs| attrs["deleted"] }.flat_map { |attrs| [ attrs["account_id"], attrs["transfer_account_id"] ] }.compact.uniq
      raise Refused, "That account no longer exists, so nothing was changed." if @budget.accounts.not_deleted.where(id: ids).count != ids.size
    end

    def restore!(to, live, live_subs)
      to["tx"].each do |id, attrs|
        row = live.fetch(id.to_i)
        attrs ? row.update!(attrs.except("public_id")) : row.update!(deleted: true)
      end
      to["sub"].each do |id, attrs|
        row = live_subs[id.to_i]
        if attrs.nil?
          row&.destroy!
        elsif row
          row.update!(attrs.except("public_id"))
        else
          SubTransaction.create!(attrs.merge("id" => id.to_i))
        end
      end
    end
end
