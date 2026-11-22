module Api
  module V1
    # YNAB account endpoints (spec: AccountsResponse, AccountResponse,
    # PostAccountWrapper). Nested under /v1/plans/:plan_id.
    class AccountsController < BaseController
      before_action :set_plan

      # GET /v1/plans/:plan_id/accounts - { data: { accounts: [...], server_knowledge } }.
      # Supports last_knowledge_of_server delta requests (spec), returning
      # tombstones for deleted accounts.
      def index
        accounts = delta_scope(plan.accounts).order(:knowledge).map { |account| AccountSerializer.as_json(account) }
        render_data({ accounts: accounts }, server_knowledge: plan.server_knowledge)
      end

      # POST /v1/plans/:plan_id/accounts - { data: { account: Account } }.
      # (spec: PostAccountWrapper). YNAB accepts a restricted type list on
      # create (spec: SaveAccountType) and auto-creates the account's
      # transfer payee.
      def create
        begin
          attributes = params.require(:account).permit(:name, :type, :balance)
        rescue ActionController::ParameterMissing
          return render_api_error(:bad_request, "Request body must include an account object with name, type and balance.", id: "400", name: "bad_request")
        end
        unless Account::SAVE_TYPES.include?(attributes[:type])
          return render_api_error(:bad_request, "The account type is not valid for creating an account.", id: "400", name: "bad_request")
        end

        unless attributes["balance"].is_a?(Integer)
          return render_api_error(:bad_request, "The balance is required and must be integer milliunits.", id: "400", name: "bad_request")
        end

        begin
          account = Account.open!(budget: plan, attributes: attributes.to_h)
        rescue ActiveRecord::RecordInvalid => error
          return render_api_error(:bad_request, error.record.errors.full_messages.to_sentence, id: "400", name: "bad_request")
        end

        render json: { data: { account: AccountSerializer.as_json(account) } }, status: :created
      end

      # GET /v1/plans/:plan_id/accounts/:account_id - { data: { account: Account } }.
      def show
        account = plan.accounts.not_deleted.find_by(public_id: params[:account_id])
        return render_api_error(:not_found, "No account was found with the given id.", id: "404.2", name: "resource_not_found") if account.nil?

        render json: { data: { account: AccountSerializer.as_json(account) } }
      end
    end
  end
end
