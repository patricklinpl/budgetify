# Serializes a Payee (spec: Payee schema). transfer_account_id is the
# account's public UUID for transfer payees, null otherwise.
class PayeeSerializer
  def self.as_json(payee)
    {
      id: payee.public_id,
      name: payee.name,
      transfer_account_id: payee.transfer_account&.public_id,
      deleted: payee.deleted
    }
  end
end
