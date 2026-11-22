# Serializes a Budget as a YNAB PlanSummary (spec: PlanSummary schema).
# Our Budget model is a YNAB "plan"; ids are the public UUIDs.
#
#   PlanSummary.as_json(plan)                          # summary fields
#   PlanSummary.as_json(plan, include_accounts: true)  # adds live accounts
#
# accounts is only present when include_accounts=true (spec: the field is
# included only when requested). Month bounds use the month endpoint's
# shared range, including historical activity.
class PlanSummary
  def self.as_json(plan, include_accounts: false)
    json = {
      id: plan.public_id,
      name: plan.name,
      last_modified_on: plan.updated_at.iso8601,
      first_month: plan.first_month.iso8601,
      last_month: plan.last_month.iso8601,
      date_format: { format: plan.date_format },
      currency_format: plan.currency_format.as_json
    }
    json[:deleted] = true if plan.deleted?
    json[:accounts] = plan.accounts.not_deleted.order(:created_at, :id).map { |account| AccountSerializer.as_json(account) } if include_accounts
    json
  end
end
