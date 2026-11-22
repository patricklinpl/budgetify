# Serializes an Account (spec: Account schema = AccountBase + currency
# triples). Balances are integer milliunits with *_currency and *_formatted
# companions (spec: CurrencyFormat); per-plan currency settings land with
# issue #27, so the USD default is used for now.
class AccountSerializer
  def self.as_json(account)
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
      Milliunits.fields(:balance, account.balance),
      Milliunits.fields(:cleared_balance, account.cleared_balance),
      Milliunits.fields(:uncleared_balance, account.uncleared_balance)
    )
  end
end
