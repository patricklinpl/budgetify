# Before and after images of the rows one Undo step touched: the transaction,
# its linked transfer pair and its split children. A row that does not exist
# is nil. Only the listed fields are stored and compared (the stale check).
module UndoSnapshot
  TX_FIELDS = %w[
    public_id account_id date amount memo cleared approved flag_color flag_name payee_id category_id
    transfer_account_id transfer_transaction_id matched_transaction_id debt_transaction_type opening_balance deleted
  ].freeze
  SUB_FIELDS = %w[public_id transaction_id amount memo payee_id category_id transfer_account_id deleted].freeze

  Ids = Struct.new(:tx, :sub) do
    def |(other) = Ids.new((tx | other.tx).sort, (sub | other.sub).sort)
  end

  module_function

  # Ids of the transaction, its transfer pair and all split children of both.
  def reachable(transaction)
    return Ids.new([], []) if transaction.nil?

    txs = [ transaction, transaction.transfer_transaction ].compact
    Ids.new(txs.map(&:id).sort, SubTransaction.where(transaction_id: txs.map(&:id)).pluck(:id).sort)
  end

  def take(budget, ids)
    txs = budget.transactions.where(id: ids.tx).index_by(&:id)
    subs = SubTransaction.where(id: ids.sub, transaction_id: budget.transactions.select(:id)).index_by(&:id)
    {
      "tx" => ids.tx.to_h { |id| [ id.to_s, txs[id]&.attributes&.slice(*TX_FIELDS)&.as_json ] },
      "sub" => ids.sub.to_h { |id| [ id.to_s, subs[id]&.attributes&.slice(*SUB_FIELDS)&.as_json ] }
    }
  end

  # Rows that did not exist when `before` was taken. A transaction is never
  # hard-deleted, so its before image is its after image marked deleted: the
  # redo stale check then compares every field, not just "still deleted". A
  # split child that did not exist stays nil (Undo removes it, Redo recreates it).
  def blank_new_rows(before, after)
    after["tx"].each { |id, attrs| before["tx"][id] = attrs&.merge("deleted" => true) unless before["tx"].key?(id) }
    after["sub"].each_key { |id| before["sub"][id] = nil unless before["sub"].key?(id) }
    before
  end
end
