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

      # PATCH /v1/plans/:plan_id/accounts/:account_id (Budgetify extension,
      # not in the YNAB schema): name, note, closed, and a tracking-account
      # balance target recorded as a Manual Balance Adjustment.
      def update
        account = plan.accounts.not_deleted.find_by(public_id: params[:account_id])
        return render_api_error(:not_found, "No account was found with the given id.", id: "404.2", name: "resource_not_found") if account.nil?

        attrs = params[:account]
        return bad_request("Request body must include an account object.") unless attrs.is_a?(ActionController::Parameters)
        unknown = attrs.keys - %w[name note closed balance]
        return bad_request("Unsupported account fields: #{unknown.sort.join(', ')}. Only name, note, closed and balance can be changed.") if unknown.any?

        attrs = attrs.permit(:name, :note, :closed, :balance)
        return bad_request("account must include name, note, closed or balance.") if attrs.keys.empty?
        return bad_request("name must be a non-blank string.") if attrs.key?(:name) && (!attrs[:name].is_a?(String) || attrs[:name].strip.empty?)
        return bad_request("note must be a string or null.") if attrs.key?(:note) && !(attrs[:note].nil? || attrs[:note].is_a?(String))
        return bad_request("closed must be true or false.") if attrs.key?(:closed) && ![ true, false ].include?(attrs[:closed])
        return bad_request("balance must be integer milliunits.") if attrs.key?(:balance) && !attrs[:balance].is_a?(Integer)

        Account.transaction do
          account.update!(name: attrs[:name].strip) if attrs.key?(:name)
          account.update!(note: attrs[:note]) if attrs.key?(:note)
          account.reopen! if attrs[:closed] == false && account.closed
          account.adjust_balance!(attrs[:balance]) if attrs.key?(:balance)
          account.close! if attrs[:closed] == true && !account.closed
        end
        render json: { data: { account: AccountSerializer.as_json(account.reload) } }
      rescue Account::Blocked => error
        render_api_error(:unprocessable_entity, error.message, id: "422", name: "unprocessable_entity")
      rescue ActiveRecord::RecordInvalid => error
        bad_request(error.record.errors.full_messages.to_sentence)
      end

      # DELETE .../accounts/:account_id: only an account whose sole activity
      # is its opening balance (TRACK-03, ACCT-LOC-01).
      def destroy
        account = plan.accounts.not_deleted.find_by(public_id: params[:account_id])
        return render_api_error(:not_found, "No account was found with the given id.", id: "404.2", name: "resource_not_found") if account.nil?

        account.delete_opening_only!
        render json: { data: { account: AccountSerializer.as_json(account.reload) } }
      rescue Account::Blocked => error
        render_api_error(:unprocessable_entity, error.message, id: "422", name: "unprocessable_entity")
      end

      private
        def bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
        end
    end
  end
end
