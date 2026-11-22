# Serializes a Budget as a YNAB PlanSummary (spec: PlanSummary schema).
# Our Budget model is a YNAB "plan"; ids are the public UUIDs.
#
#   PlanSummary.as_json(plan)                          # summary fields
#   PlanSummary.as_json(plan, include_accounts: true)  # adds "accounts": []
#
# accounts is only present when include_accounts=true (spec: the field is
# included only when requested). first_month/last_month are omitted until
# the months work lands; both are optional in the spec.
class PlanSummary
  def self.as_json(plan, include_accounts: false)
    json = {
      id: plan.public_id,
      name: plan.name,
      last_modified_on: plan.updated_at.iso8601,
      date_format: { format: plan.date_format },
      currency_format: plan.currency_format.as_json
    }
    json[:deleted] = true if plan.deleted?
    json[:accounts] = [] if include_accounts
    json
  end
end
