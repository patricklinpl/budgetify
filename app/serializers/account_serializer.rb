# Serializes an Account (spec: Account schema = AccountBase + currency
# triples). Balances are integer milliunits with *_currency and *_formatted
# companions rendered with the owning plan's persisted CurrencyFormat.
class AccountSerializer
  def self.as_json(account)
    currency_format = account.budget.currency_format
    {
      id: account.public_id,
      name: account.name,
      type: account.type,
      on_budget: account.on_budget,
      closed: account.closed,
      note: account.note,
      transfer_payee_id: account.transfer_payee&.public_id,
      direct_import_linked: false,
      direct_import_in_error: false,
      last_reconciled_at: account.last_reconciled_at&.iso8601,
      debt_original_balance: nil,
      debt_interest_rates: {},
      debt_minimum_payments: {},
      debt_escrow_amounts: {},
      deleted: account.deleted
    }.merge!(
      Milliunits.fields(:balance, account.balance, currency_format),
      Milliunits.fields(:cleared_balance, account.cleared_balance, currency_format),
      Milliunits.fields(:uncleared_balance, account.uncleared_balance, currency_format)
    )
  end
end
