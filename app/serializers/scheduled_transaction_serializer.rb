# Serializes scheduled transactions (spec: ScheduledTransactionSummary,
# ScheduledTransactionDetail). Amounts are integer milliunits with
# *_currency/*_formatted companions (spec: CurrencyFormat). Detail adds
# account/payee/category names and subtransactions.
class ScheduledTransactionSerializer
  def self.summary_as_json(scheduled)
    new(scheduled).summary_as_json
  end

  def self.detail_as_json(scheduled)
    summary_as_json(scheduled).merge(
      account_name: scheduled.account.name,
      payee_name: scheduled.payee&.name,
      category_name: scheduled.scheduled_sub_transactions.exists? ? "Split" : scheduled.category&.name,
      subtransactions: scheduled.scheduled_sub_transactions.not_deleted.map { |sub| ScheduledSubTransactionSerializer.as_json(sub) }
    )
  end

  def initialize(scheduled)
    @scheduled = scheduled
  end

  def summary_as_json
    scheduled = @scheduled
    currency_format = scheduled.budget.currency_format
    {
      id: scheduled.public_id,
      date_first: scheduled.date_first&.iso8601,
      date_next: scheduled.date_next&.iso8601,
      frequency: scheduled.frequency,
      **Milliunits.fields(:amount, scheduled.amount, currency_format),
      memo: scheduled.memo,
      flag_color: scheduled.flag_color,
      flag_name: scheduled.flag_name,
      account_id: scheduled.account.public_id,
      payee_id: scheduled.payee&.public_id,
      category_id: scheduled.category&.public_id,
      transfer_account_id: scheduled.transfer_account&.public_id,
      deleted: scheduled.deleted
    }
  end
end
