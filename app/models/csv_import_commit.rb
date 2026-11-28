# Writes a previewed CSV import. It reads the stored file again and plans it
# against the data as it is now, and refuses when that plan is not the one the
# user confirmed (the digest). Everything is written in one database
# transaction and recorded as one Undo step; any failure writes nothing.
#
# [reference] YNAB's File-Based Import and Approving and Matching help pages:
# - A matched pair keeps the date, payee, memo and category the user entered
#   and is approved automatically. The amounts are equal by the matching rule.
# - Categories and splits are not imported.
# [engineering] My choices, not observed or documented:
# - A new row is uncleared, unapproved and has no category. (YNAB's help page now
#   says imports auto-categorize by the payee's usual category and clean up
#   payees. That is not built; it is open for the owner to decide.)
# - A match keeps the bank row as a hidden counterpart: a deleted transaction
#   that carries the import id and the link, so balances are unchanged and a
#   second import of the file skips the row. The manual transaction links to it
#   through matched_transaction_id and keeps its cleared state.
# - Undo of the import also clears the import id on the rows it removes, so
#   importing the same file again after an Undo brings them back.
# - One Undo step has a larger size cap than an ordinary edit.
class CsvImportCommit
  class Refused < StandardError; end

  STEP_MAX_BYTES = 8 * 1024 * 1024
  Outcome = Struct.new(:created, :matched, :skipped, keyword_init: true)

  def self.digest(plan)
    Digest::SHA256.hexdigest(plan.rows.map { |r| [ r.line, r.date.iso8601, r.amount, r.status, r.matched_transaction&.id, r.import_id ] }.to_json)
  end

  def initialize(budget:, account:, draft:, user:, history:, digest:)
    @budget = budget
    @account = account
    @draft = draft
    @user = user
    @history = history
    @digest = digest.to_s
  end

  def call
    raise Refused, "That account is closed, so nothing was imported." if @account.closed
    plan = CsvImport.plan(@draft.data, account: @account, **@draft.settings)
    raise Refused, "The preview no longer matches the account, so nothing was imported. Preview the file again." unless ActiveSupport::SecurityUtils.secure_compare(self.class.digest(plan), @digest)
    todo = plan.rows.select { |row| %i[new matched].include?(row.status) }
    raise Refused, "There is nothing to import: every row was skipped." if todo.empty?

    writer = TransactionWriter.new(@budget)
    outcome = Outcome.new(created: 0, matched: 0, skipped: plan.rows.size - todo.size)
    Transaction.transaction do
      manual_ids = todo.filter_map { |row| row.matched_transaction&.id }.sort
      before = UndoSnapshot.take(@budget, UndoSnapshot::Ids.new(manual_ids, []))
      new_ids = todo.filter_map { |row| row.status == :matched ? link!(row, outcome) : add!(writer, row, outcome) }
      ids = UndoSnapshot::Ids.new((manual_ids | new_ids).sort, [])
      after = UndoSnapshot.take(@budget, ids)
      before = UndoSnapshot.blank_new_rows(before, after)
      new_ids.each { |id| before["tx"][id.to_s] = before["tx"][id.to_s].merge("import_id" => nil, "matched_transaction_id" => nil) }
      @history&.record!(kind: :import, before: before, after: after, max_bytes: STEP_MAX_BYTES)
    end
    @draft.destroy!
    outcome
  end

  private
    def add!(writer, row, outcome)
      attributes = { "account_id" => @account.public_id, "date" => row.date.iso8601, "amount" => row.amount, "memo" => row.memo,
        "cleared" => "uncleared", "approved" => false, "import_id" => row.import_id,
        "import_payee_name" => row.payee, "import_payee_name_original" => row.payee, "payee_name" => row.payee }.compact
      transaction = writer.persist_new!(writer.build(attributes))
      outcome.created += 1
      transaction.id
    rescue TransactionWriter::Invalid => e
      raise Refused, "Line #{row.line}: #{e.message} Nothing was imported."
    end

    def link!(row, outcome)
      manual = @budget.transactions.lock.find(row.matched_transaction.id)
      unless manual.deleted == false && manual.import_id.blank? && manual.matched_transaction_id.nil? && manual.cleared != "reconciled"
        raise Refused, "Line #{row.line}: the matching transaction changed, so nothing was imported. Preview the file again."
      end
      bank = @budget.transactions.create!(account: @account, date: row.date, amount: row.amount, memo: row.memo, cleared: "uncleared",
        approved: true, deleted: true, import_id: row.import_id, import_payee_name: row.payee, import_payee_name_original: row.payee,
        matched_transaction: manual)
      manual.update!(matched_transaction: bank, approved: true)
      outcome.matched += 1
      bank.id
    end
end
