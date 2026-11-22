# Serializes a SubTransaction (spec: SubTransaction schema, nested under
# TransactionDetail).
class SubTransactionSerializer
  def self.as_json(sub)
    currency_format = sub.parent_transaction.budget.currency_format
    {
      id: sub.public_id,
      transaction_id: sub.parent_transaction.public_id,
      **Milliunits.fields(:amount, sub.amount, currency_format),
      memo: sub.memo,
      payee_id: sub.payee&.public_id,
      payee_name: sub.payee&.name,
      category_id: sub.category&.public_id,
      category_name: sub.category&.name,
      transfer_account_id: sub.transfer_account&.public_id,
      transfer_transaction_id: nil,
      deleted: sub.deleted
    }
  end
end
