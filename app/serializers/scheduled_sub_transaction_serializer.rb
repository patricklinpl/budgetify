# Serializes a ScheduledSubTransaction (spec: ScheduledSubTransaction
# schema, nested under ScheduledTransactionDetail).
class ScheduledSubTransactionSerializer
  def self.as_json(sub)
    currency_format = sub.scheduled_transaction.budget.currency_format
    {
      id: sub.public_id,
      scheduled_transaction_id: sub.scheduled_transaction.public_id,
      **Milliunits.fields(:amount, sub.amount, currency_format),
      memo: sub.memo,
      payee_id: sub.payee&.public_id,
      payee_name: sub.payee&.name,
      category_id: sub.category&.public_id,
      category_name: sub.category&.name,
      transfer_account_id: sub.transfer_account&.public_id,
      deleted: sub.deleted
    }
  end
end
