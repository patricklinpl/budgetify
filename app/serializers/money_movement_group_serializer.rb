# Serializes a MoneyMovementGroup (spec: MoneyMovementGroup schema).
class MoneyMovementGroupSerializer
  def self.as_json(group)
    {
      id: group.public_id,
      group_created_at: group.group_created_at&.iso8601,
      month: group.month&.iso8601,
      note: group.note,
      performed_by_user_id: group.performed_by_user&.public_id
    }
  end
end
