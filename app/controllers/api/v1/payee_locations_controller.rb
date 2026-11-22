module Api
  module V1
    # YNAB payee location endpoints (spec: PayeeLocationsResponse,
    # PayeeLocationResponse). Locations are read-only in the YNAB API, so
    # only the three list/show endpoints exist. Nested under
    # /v1/plans/:plan_id.
    class PayeeLocationsController < BaseController
      before_action :set_plan

      # GET /v1/plans/:plan_id/payee_locations -
      # { data: { payee_locations: [...] } }. Supports
      # last_knowledge_of_server delta requests with tombstones.
      def index
        locations = delta_scope(plan_locations).order(:knowledge).map { |location| PayeeLocationSerializer.as_json(location) }
        render_data({ payee_locations: locations })
      end

      # GET /v1/plans/:plan_id/payee_locations/:payee_location_id -
      # { data: { payee_location: PayeeLocation } }.
      def show
        location = plan_locations.not_deleted.find_by(public_id: params[:payee_location_id])
        return render_api_error(:not_found, "No payee location was found with the given id.", id: "404.2", name: "resource_not_found") if location.nil?

        render_data({ payee_location: PayeeLocationSerializer.as_json(location) })
      end

      # GET /v1/plans/:plan_id/payees/:payee_id/payee_locations -
      # { data: { payee_locations: [...] } } for one payee.
      def for_payee
        payee = plan.payees.not_deleted.find_by(public_id: params[:payee_id])
        return render_api_error(:not_found, "No payee was found with the given id.", id: "404.2", name: "resource_not_found") if payee.nil?

        locations = delta_scope(payee.payee_locations).order(:knowledge).map { |location| PayeeLocationSerializer.as_json(location) }
        render_data({ payee_locations: locations })
      end

      private
        def plan_locations
          PayeeLocation.joins(:payee).where(payees: { budget_id: plan.id })
        end
    end
  end
end
