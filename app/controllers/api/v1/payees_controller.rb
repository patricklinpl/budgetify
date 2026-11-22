module Api
  module V1
    # YNAB payee endpoints (spec: PayeesResponse, PayeeResponse,
    # SavePayeeResponse, PostPayeeWrapper, PatchPayeeWrapper). Nested under
    # /v1/plans/:plan_id.
    class PayeesController < BaseController
      before_action :set_plan

      # GET /v1/plans/:plan_id/payees - { data: { payees: [...], server_knowledge } }.
      # Supports last_knowledge_of_server delta requests (spec), returning
      # tombstones for deleted payees.
      def index
        payees = delta_scope(plan.payees).order(:knowledge).map { |payee| PayeeSerializer.as_json(payee) }
        render_data({ payees: payees }, server_knowledge: plan.server_knowledge)
      end

      # POST /v1/plans/:plan_id/payees - { data: { payee: Payee, server_knowledge } }
      # (spec: PostPayeeWrapper / SavePayeeResponse). Duplicate names and
      # names with characters other than letters/numbers/spaces are 400.
      def create
        attributes = permitted_payee_params
        return if attributes.nil?
        return render_bad_request("The payee name is required.") if attributes["name"].blank?

        payee = plan.payees.new(attributes)
        return render_bad_request(payee.errors.full_messages.to_sentence) unless payee.save

        render json: { data: { payee: PayeeSerializer.as_json(payee), server_knowledge: plan.reload.server_knowledge } }, status: :created
      end

      # GET /v1/plans/:plan_id/payees/:payee_id - { data: { payee: Payee } }.
      def show
        payee = find_payee
        return if payee.nil?

        render_data({ payee: PayeeSerializer.as_json(payee) })
      end

      # PATCH /v1/plans/:plan_id/payees/:payee_id -
      # { data: { payee: Payee, server_knowledge } } (spec: SavePayeeResponse).
      # Transfer payees are managed through their account and cannot be
      # renamed here (spec: 400).
      def update
        payee = find_payee
        return if payee.nil?
        return render_bad_request("Transfer payees cannot be renamed.") if payee.transfer_payee?

        attributes = permitted_payee_params
        return if attributes.nil?
        return render_bad_request("The payee name is required.") if attributes.key?("name") && attributes["name"].blank?
        return render_bad_request(payee.errors.full_messages.to_sentence) unless payee.update(attributes)

        render_data({ payee: PayeeSerializer.as_json(payee) }, server_knowledge: plan.reload.server_knowledge)
      end

      private
        def permitted_payee_params
          params.require(:payee).permit(:name).to_h
        rescue ActionController::ParameterMissing
          render_bad_request("Request body must include a payee object.")
          nil
        end

        def find_payee
          payee = plan.payees.not_deleted.find_by(public_id: params[:payee_id])
          render_api_error(:not_found, "No payee was found with the given id.", id: "404.2", name: "resource_not_found") if payee.nil?
          payee
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end
    end
  end
end
