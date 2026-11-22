# Serializes a MoneyMovement (spec: MoneyMovement = MoneyMovementBase +
# amount currency companions). from_category_id/to_category_id are null
# when the movement is to/from Ready to Assign (spec: nullable).
class MoneyMovementSerializer
  def self.as_json(movement)
    currency_format = movement.budget.currency_format
    {
      id: movement.public_id,
      month: movement.month&.iso8601,
      moved_at: movement.moved_at&.iso8601,
      note: movement.note,
      money_movement_group_id: movement.money_movement_group&.public_id,
      performed_by_user_id: movement.performed_by_user&.public_id,
      from_category_id: movement.from_category&.public_id,
      to_category_id: movement.to_category&.public_id,
      **Milliunits.fields(:amount, movement.amount, currency_format)
    }
  end
end
