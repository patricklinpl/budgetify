module Api
  module V1
    # YNAB transaction endpoints (spec: TransactionsResponse,
    # TransactionResponse, SaveTransactionsResponse,
    # TransactionsImportResponse, HybridTransactionsResponse). Nested
    # under /v1/plans/:plan_id.
    class TransactionsController < BaseController
      before_action :set_plan
      rescue_from TransactionWriter::Invalid do |error|
        render_bad_request(error.message)
      end
      before_action :set_month, only: :for_month

      # GET /v1/plans/:plan_id/transactions - { data: { transactions: [TransactionSummary], server_knowledge } }.
      # Filters: since_date, until_date (ISO dates), type=uncategorized|unapproved,
      # last_knowledge_of_server delta (spec: getTransactions).
      def index
        transactions = filtered_scope(plan.transactions)
        return if transactions.nil?

        render_data({
          transactions: transactions.map { |transaction| TransactionSerializer.detail_as_json(transaction) },
          server_knowledge: plan.server_knowledge
        })
      end

      # GET /v1/plans/:plan_id/accounts/:account_id/transactions - hybrid
      # list for one account (spec: getTransactionsByAccount).
      def for_account
        account = plan.accounts.not_deleted.find_by(public_id: params[:account_id])
        return render_not_found("No account was found with the given id.") if account.nil?

        transactions = filtered_scope(account.transactions)
        return if transactions.nil?

        render_hybrid(transactions, sub_scope: plan_sub_transactions.joins(:parent_transaction).where(transactions: { account_id: account.id }))
      end

      # GET /v1/plans/:plan_id/categories/:category_id/transactions - hybrid
      # list for one category, including subtransactions (spec:
      # getTransactionsByCategory).
      def for_category
        category = plan.categories.not_deleted.find_by(public_id: params[:category_id])
        return render_not_found("No category was found with the given id.") if category.nil?

        transactions = filtered_scope(plan.transactions.where(category_id: category.id))
        return if transactions.nil?

        render_hybrid(transactions, sub_scope: plan_sub_transactions.where(category_id: category.id))
      end

      # GET /v1/plans/:plan_id/payees/:payee_id/transactions - hybrid list
      # for one payee, including subtransactions (spec:
      # getTransactionsByPayee).
      def for_payee
        payee = plan.payees.not_deleted.find_by(public_id: params[:payee_id])
        return render_not_found("No payee was found with the given id.") if payee.nil?

        transactions = filtered_scope(plan.transactions.where(payee_id: payee.id))
        return if transactions.nil?

        render_hybrid(transactions, sub_scope: plan_sub_transactions.where(payee_id: payee.id))
      end

      # GET /v1/plans/:plan_id/months/:month/transactions - hybrid list for
      # one plan month (spec: getTransactionsByMonth).
      def for_month
        return if @month.nil?

        transactions = filtered_scope(plan.transactions.where(date: @month..@month.end_of_month))
        return if transactions.nil?

        render_hybrid(transactions, sub_scope: plan_sub_transactions.joins(:parent_transaction).where(transactions: { date: @month..@month.end_of_month }))
      end

      # GET /v1/plans/:plan_id/transactions/:transaction_id -
      # { data: { transaction: TransactionDetail } }.
      def show
        transaction = find_transaction
        return if transaction.nil?

        render_data({ transaction: TransactionSerializer.detail_as_json(transaction), server_knowledge: plan.server_knowledge })
      end

      # POST /v1/plans/:plan_id/transactions - create one transaction
      # ({ transaction: {...} }) or many ({ transactions: [...] }) (spec:
      # PostTransactionsWrapper / NewTransaction). Same-import_id creates
      # are reported in duplicate_import_ids instead of duplicated.
      def create
        if params[:transactions].present?
          return create_bulk
        end

        attributes = permitted_transaction_params(:transaction)
        return if attributes.nil?

        transaction = writer.build(attributes)

        # import_id dedupe is per account (spec: NewTransaction.import_id).
        if attributes["import_id"].present? &&
           plan.transactions.not_deleted.exists?(account: transaction.account, import_id: attributes["import_id"])
          return render json: { data: {
            transaction_ids: [],
            duplicate_import_ids: [ attributes["import_id"] ],
            server_knowledge: plan.server_knowledge
          } }, status: :created
        end

        writer.persist_new!(transaction)
        render json: { data: {
          transaction_ids: [ transaction.public_id ],
          duplicate_import_ids: [],
          transaction: TransactionSerializer.detail_as_json(transaction.reload),
          server_knowledge: plan.reload.server_knowledge
        } }, status: :created
      end

      # PUT /v1/plans/:plan_id/transactions/:transaction_id - update one
      # transaction (spec: PutTransactionWrapper / SaveTransactionWithOptionalFields).
      def update
        transaction = find_transaction
        return if transaction.nil?

        attributes = permitted_transaction_params(:transaction)
        return if attributes.nil?

        # Reverse, re-apply and re-sync the transfer pair atomically: a
        # validation or lookup failure after reversal must not leave
        # balances reduced (issue #33: account balances update from
        # transaction writes).
        Transaction.transaction { writer.update!(transaction, attributes, rebuild_subs: true) }
        render_data({
          transaction_ids: [ transaction.public_id ],
          transaction: TransactionSerializer.detail_as_json(transaction.reload),
          server_knowledge: plan.reload.server_knowledge
        })
      end

      # PATCH /v1/plans/:plan_id/transactions - bulk update by id or
      # import_id (spec: PatchTransactionsWrapper /
      # SaveTransactionWithIdOrImportId).
      def update_bulk
        entries = params[:transactions]
        return render_bad_request("Request body must include a transactions array.") unless entries.is_a?(Array)

        updated = []
        # All-or-nothing: an unknown id/import_id, invalid field or future
        # date fails the request instead of being silently skipped or
        # half-applied (spec: SaveTransactionWithIdOrImportId).
        Transaction.transaction do
          entries.each do |entry|
            attributes = entry.respond_to?(:permit) ? entry.permit!.to_h : entry.to_h
            transaction = if attributes["id"].present?
              plan.transactions.not_deleted.find_by(public_id: attributes["id"])
            elsif attributes["import_id"].present?
              plan.transactions.not_deleted.find_by(import_id: attributes["import_id"])
            end
            if transaction.nil?
              render_bad_request("A transaction was not found for the given id or import_id.")
              raise ActiveRecord::Rollback
            end
            writer.update!(transaction, attributes.except("id"), rebuild_subs: false)
            updated << transaction
          end
        end
        return if performed?

        render_data({
          transaction_ids: updated.map(&:public_id),
          transactions: updated.map { |transaction| TransactionSerializer.detail_as_json(transaction) },
          duplicate_import_ids: [],
          server_knowledge: plan.reload.server_knowledge
        })
      end

      # DELETE /v1/plans/:plan_id/transactions/:transaction_id - soft
      # delete (spec: deleteTransaction returns the deleted transaction).
      def destroy
        transaction = find_transaction
        return if transaction.nil?

        Transaction.transaction { writer.destroy!(transaction) }
        render_data({ transaction: TransactionSerializer.detail_as_json(transaction.reload), server_knowledge: plan.reload.server_knowledge })
      end

      # POST /v1/plans/:plan_id/transactions/import - YNAB deprecated
      # import; returns an empty id list (issue #33: optional stub).
      def import
        render_data({ transaction_ids: [], duplicate_import_ids: [], server_knowledge: plan.reload.server_knowledge }, status: :created)
      end

      private
        def create_bulk
          entries = params[:transactions]
          attributes_list = entries.map { |entry| entry.respond_to?(:permit) ? entry.permit!.to_h : entry.to_h }
          seen = []
          created = []
          duplicate_import_ids = []
          attributes_list.each do |attributes|
            transaction = writer.build(attributes)

            # import_id dedupe is per account, including repeats within
            # the same bulk request (spec: NewTransaction.import_id).
            import_id = attributes["import_id"]
            if import_id.present? &&
               (seen.include?([ transaction.account_id, import_id ]) ||
                plan.transactions.not_deleted.exists?(account: transaction.account, import_id: import_id))
              duplicate_import_ids << import_id
              next
            end

            writer.persist_new!(transaction)

            seen << [ transaction.account_id, import_id ] if import_id.present?
            created << transaction
          end

          render json: { data: {
            transaction_ids: created.map(&:public_id),
            transactions: created.map { |transaction| TransactionSerializer.detail_as_json(transaction) },
            duplicate_import_ids: duplicate_import_ids,
            server_knowledge: plan.reload.server_knowledge
          } }, status: :created
        end

        def writer
          @writer ||= TransactionWriter.new(plan)
        end

        def find_transaction
          transaction = plan.transactions.not_deleted.find_by(public_id: params[:transaction_id])
          render_not_found("No transaction was found with the given id.") if transaction.nil?
          transaction
        end

        # Returns nil (after rendering a 400) when a date filter is not an
        # ISO date (spec: 400 on invalid query parameters).
        def filtered_scope(scope)
          scope = scope.not_deleted.order(:date, :knowledge)
          knowledge = params[:last_knowledge_of_server]
          scope = scope.where(knowledge: (knowledge.to_i + 1)..) if knowledge.present?
          begin
            scope = scope.where("date >= ?", Date.iso8601(params[:since_date])) if params[:since_date].present?
            scope = scope.where("date <= ?", Date.iso8601(params[:until_date])) if params[:until_date].present?
          rescue ArgumentError, TypeError
            render_bad_request("The date filter is not valid; use ISO format (e.g. 2016-12-01).")
            return nil
          end
          case params[:type]
          when "uncategorized"
            # Split parents are categorized via their subtransactions, so
            # they are not uncategorized (spec: getTransactions type).
            scope = scope.where(category_id: nil).where.not(id: SubTransaction.where(deleted: false).select(:transaction_id))
          when "unapproved"
            scope = scope.where(approved: false)
          end
          scope.includes(:account, :payee, :category, :transfer_account, :sub_transactions)
        end

        # Sub scope is supplied fully-scoped to the plan: split parents carry no
        # category/payee of their own, so filtering subs by the main list's ids
        # would drop split rows (spec: HybridTransaction type=subtransaction).
        def render_hybrid(transactions, sub_scope: nil)
          rows = transactions.map { |transaction| TransactionSerializer.hybrid_as_json(transaction) }
          if sub_scope
            sub_scope = sub_scope.not_deleted
            knowledge = params[:last_knowledge_of_server]
            sub_scope = sub_scope.where(knowledge: (knowledge.to_i + 1)..) if knowledge.present?
            subs = sub_scope.includes(parent_transaction: [ :account, :budget ])
            rows.concat(subs.map { |sub| TransactionSerializer.hybrid_sub_as_json(sub) })
          end
          render_data({ transactions: rows, server_knowledge: plan.server_knowledge })
        end

        def plan_sub_transactions
          SubTransaction.where(transaction_id: plan.transactions.select(:id))
        end

        def render_not_found(detail)
          render_api_error(:not_found, detail, id: "404.2", name: "resource_not_found")
          nil
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end

        def permitted_transaction_params(key)
          params.require(key).permit(
            :account_id, :date, :amount, :payee_id, :payee_name, :category_id,
            :transfer_account_id,
            :memo, :cleared, :approved, :flag_color, :flag_name, :import_id,
            :import_payee_name, :import_payee_name_original,
            subtransactions: [ :amount, :memo, :payee_id, :payee_name, :category_id ]
          ).to_h
        rescue ActionController::ParameterMissing
          render_bad_request("Request body must include a #{key} object.")
          nil
        end

        # "current" resolves to the current calendar month (UTC); otherwise
        # an ISO plan month (first of month). Invalid or future months get
        # a 400 (spec: 400 on the month endpoints).
        def set_month
          current = Date.current.beginning_of_month
          if params[:month] == "current"
            @month = current
            return
          end

          @month = Date.iso8601(params[:month]).beginning_of_month
          if @month > current
            render_api_error(:bad_request, "The month cannot be in the future.", id: "400", name: "bad_request")
            @month = nil
          end
        rescue ArgumentError, TypeError
          render_api_error(:bad_request, "The month is not valid; use ISO format (e.g. 2016-12-01) or \"current\".", id: "400", name: "bad_request")
          @month = nil
        end
    end
  end
end
