# Serializes transactions (spec: TransactionSummary, TransactionDetail,
# HybridTransaction). Summary fields carry integer milliunit amounts with
# *_currency/*_formatted companions (spec: CurrencyFormat). Detail adds
# account/payee/category names and subtransactions; scoped lists return
# hybrid rows adding type and parent_transaction_id (spec:
# HybridTransaction).
class TransactionSerializer
  def self.summary_as_json(transaction)
    new(transaction).summary_as_json
  end

  def self.detail_as_json(transaction)
    new(transaction).summary_as_json.merge(
      account_name: transaction.account.name,
      payee_name: transaction.payee&.name,
      category_name: transaction.sub_transactions.exists? ? "Split" : transaction.category&.name,
      subtransactions: transaction.sub_transactions.not_deleted.map { |sub| SubTransactionSerializer.as_json(sub) }
    )
  end

  def self.hybrid_as_json(transaction)
    new(transaction).summary_as_json.merge(
      type: "transaction",
      parent_transaction_id: nil,
      account_name: transaction.account.name,
      payee_name: transaction.payee&.name,
      category_name: transaction.sub_transactions.exists? ? "Split" : transaction.category&.name
    ).tap { |row| row.delete(:category_name) if row[:category_name].nil? }
  end

  def self.hybrid_sub_as_json(sub)
    transaction = sub.parent_transaction
    currency_format = transaction.budget.currency_format
    {
      id: sub.public_id,
      date: transaction.date&.iso8601,
      amount: sub.amount,
      memo: sub.memo,
      cleared: transaction.cleared,
      approved: transaction.approved,
      flag_color: transaction.flag_color,
      flag_name: transaction.flag_name,
      account_id: transaction.account.public_id,
      payee_id: sub.payee&.public_id,
      category_id: sub.category&.public_id,
      transfer_account_id: sub.transfer_account&.public_id,
      transfer_transaction_id: nil,
      matched_transaction_id: nil,
      import_id: nil,
      import_payee_name: nil,
      import_payee_name_original: nil,
      debt_transaction_type: nil,
      deleted: sub.deleted,
      type: "subtransaction",
      parent_transaction_id: transaction.public_id,
      account_name: transaction.account.name,
      payee_name: sub.payee&.name,
      category_name: sub.category&.name,
      **Milliunits.fields(:amount, sub.amount, currency_format).except(:amount)
    }.tap { |row| row.delete(:category_name) if row[:category_name].nil? }
  end

  def initialize(transaction)
    @transaction = transaction
  end

  def summary_as_json
    transaction = @transaction
    currency_format = transaction.budget.currency_format
    {
      id: transaction.public_id,
      date: transaction.date&.iso8601,
      **Milliunits.fields(:amount, transaction.amount, currency_format),
      memo: transaction.memo,
      cleared: transaction.cleared,
      approved: transaction.approved,
      flag_color: transaction.flag_color,
      flag_name: transaction.flag_name,
      account_id: transaction.account.public_id,
      payee_id: transaction.payee&.public_id,
      category_id: transaction.category&.public_id,
      transfer_account_id: transaction.transfer_account&.public_id,
      transfer_transaction_id: transaction.transfer_transaction&.public_id,
      matched_transaction_id: transaction.matched_transaction&.public_id,
      import_id: transaction.import_id,
      import_payee_name: transaction.import_payee_name,
      import_payee_name_original: transaction.import_payee_name_original,
      debt_transaction_type: transaction.debt_transaction_type,
      deleted: transaction.deleted
    }
  end
end
