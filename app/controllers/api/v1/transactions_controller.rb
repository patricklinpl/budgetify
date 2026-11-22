module Api
  module V1
    # YNAB transaction endpoints (spec: TransactionsResponse,
    # TransactionResponse, SaveTransactionsResponse,
    # TransactionsImportResponse, HybridTransactionsResponse). Nested
    # under /v1/plans/:plan_id.
    class TransactionsController < BaseController
      before_action :set_plan
      before_action :set_month, only: :for_month

      # GET /v1/plans/:plan_id/transactions - { data: { transactions: [TransactionSummary], server_knowledge } }.
      # Filters: since_date, until_date (ISO dates), type=uncategorized|unapproved,
      # last_knowledge_of_server delta (spec: getTransactions).
      def index
        transactions = filtered_scope(plan.transactions)
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

        render_hybrid(filtered_scope(account.transactions))
      end

      # GET /v1/plans/:plan_id/categories/:category_id/transactions - hybrid
      # list for one category, including subtransactions (spec:
      # getTransactionsByCategory).
      def for_category
        category = plan.categories.not_deleted.find_by(public_id: params[:category_id])
        return render_not_found("No category was found with the given id.") if category.nil?

        render_hybrid(filtered_scope(plan.transactions.where(category_id: category.id)), sub_scope: plan_sub_transactions.where(category_id: category.id))
      end

      # GET /v1/plans/:plan_id/payees/:payee_id/transactions - hybrid list
      # for one payee, including subtransactions (spec:
      # getTransactionsByPayee).
      def for_payee
        payee = plan.payees.not_deleted.find_by(public_id: params[:payee_id])
        return render_not_found("No payee was found with the given id.") if payee.nil?

        render_hybrid(filtered_scope(plan.transactions.where(payee_id: payee.id)), sub_scope: plan_sub_transactions.where(payee_id: payee.id))
      end

      # GET /v1/plans/:plan_id/months/:month/transactions - hybrid list for
      # one plan month (spec: getTransactionsByMonth).
      def for_month
        return if @month.nil?

        render_hybrid(filtered_scope(plan.transactions.where(date: @month..@month.end_of_month)))
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

        if attributes["import_id"].present? &&
           plan.transactions.not_deleted.exists?(import_id: attributes["import_id"])
          return render json: { data: {
            transaction_ids: [],
            duplicate_import_ids: [ attributes["import_id"] ],
            server_knowledge: plan.server_knowledge
          } }, status: :created
        end

        transaction = build_transaction(attributes)
        return if transaction.nil?
        return render_bad_request(transaction.errors.full_messages.to_sentence) unless transaction.save

        sync_transfer!(transaction)
        transaction.apply_amounts!(+1)
        transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, +1) }
        render json: { data: {
          transaction_ids: [ transaction.public_id ],
          duplicate_import_ids: [],
          transaction: TransactionSerializer.detail_as_json(transaction),
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
        if attributes["date"].present?
          begin
            return render_bad_request("The transaction date cannot be in the future.") if Date.iso8601(attributes["date"].to_s) > Date.current
          rescue ArgumentError, TypeError
            return render_bad_request("The transaction date is not valid; use ISO format (e.g. 2016-12-01).")
          end
        end
        return render_bad_request("The subtransactions must add up to the transaction amount.") unless sub_amounts_valid?(attributes, transaction.amount)

        transaction.apply_amounts!(-1) # reverse the old effects
        transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, -1) }
        return unless assign_transaction_attributes(transaction, attributes)
        return render_bad_request(transaction.errors.full_messages.to_sentence) unless transaction.save

        rebuild_sub_transactions(transaction, attributes["subtransactions"])
        sync_transfer!(transaction)
        transaction.apply_amounts!(+1)
        transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, +1) }
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
        entries.each do |entry|
          attributes = entry.respond_to?(:permit) ? entry.permit!.to_h : entry.to_h
          transaction = if attributes["id"].present?
            plan.transactions.not_deleted.find_by(public_id: attributes["id"])
          elsif attributes["import_id"].present?
            plan.transactions.not_deleted.find_by(import_id: attributes["import_id"])
          end
          next if transaction.nil?

          transaction.apply_amounts!(-1)
          assign_transaction_attributes(transaction, attributes.except("id"))
          next unless transaction.save

          transaction.apply_amounts!(+1)
          updated << transaction
        end

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

        transaction.apply_amounts!(-1)
        transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, -1) }
        transaction.update!(deleted: true)
        transaction.transfer_transaction&.update!(deleted: true)
        render_data({ transaction: TransactionSerializer.detail_as_json(transaction.reload) })
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
          seen = plan.transactions.not_deleted.where(import_id: attributes_list.map { |a| a["import_id"] }.compact).distinct.pluck(:import_id)
          created = []
          attributes_list.each do |attributes|
            next if attributes["import_id"].present? && seen.include?(attributes["import_id"])

            transaction = build_transaction(attributes)
            return if transaction.nil?
            return render_bad_request(transaction.errors.full_messages.to_sentence) unless transaction.save

            sync_transfer!(transaction)
            transaction.apply_amounts!(+1)
            transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, +1) }
            created << transaction
          end

          render json: { data: {
            transaction_ids: created.map(&:public_id),
            transactions: created.map { |transaction| TransactionSerializer.detail_as_json(transaction) },
            duplicate_import_ids: seen,
            server_knowledge: plan.reload.server_knowledge
          } }, status: :created
        end

        def build_transaction(attributes)
          return render_bad_request("The transaction date cannot be in the future.") if attributes["date"].blank?
          date = begin
            Date.iso8601(attributes["date"].to_s)
          rescue ArgumentError, TypeError
            return render_bad_request("The transaction date is not valid; use ISO format (e.g. 2016-12-01).")
          end
          return render_bad_request("The transaction date cannot be in the future.") if date > Date.current

          account = plan.accounts.not_deleted.find_by(public_id: attributes["account_id"])
          return render_bad_request("The account_id is not valid.") if account.nil?

          transaction = plan.transactions.new(account: account)
          return unless assign_transaction_attributes(transaction, attributes)
          return render_bad_request(transaction.errors.full_messages.to_sentence) unless transaction.valid?
          return render_bad_request("The subtransactions must add up to the transaction amount.") unless sub_amounts_valid?(attributes, transaction.amount)

          build_sub_transactions(transaction, attributes["subtransactions"])
          transaction
        end

        # Split transactions require the subtransaction amounts to sum to
        # the parent amount (spec: NewTransaction.subtransactions).
        def sub_amounts_valid?(attributes, parent_amount)
          entries = attributes["subtransactions"]
          return true if entries.nil?

          total = entries.sum { |entry| (entry.respond_to?(:[]) ? entry["amount"].to_i : 0) }
          total == (attributes.key?("amount") && !attributes["amount"].nil? ? attributes["amount"].to_i : parent_amount.to_i)
        end

        # Assigns permitted save fields, resolving payee by id or creating
        # by payee_name, category by id, and transfer accounts via the
        # transfer payee (spec: NewTransaction / SaveTransaction).
        def assign_transaction_attributes(transaction, attributes)
          transaction.date = attributes["date"] if attributes["date"].present?
          transaction.amount = attributes["amount"] if attributes.key?("amount") && !attributes["amount"].nil?
          transaction.memo = attributes["memo"] if attributes.key?("memo")
          transaction.cleared = attributes["cleared"] if attributes["cleared"].present?
          transaction.approved = attributes["approved"] unless attributes["approved"].nil?
          transaction.flag_color = attributes["flag_color"].presence
          transaction.flag_name = attributes["flag_name"]
          transaction.import_id = attributes["import_id"] if attributes["import_id"].present?
          transaction.import_payee_name = attributes["import_payee_name"] if attributes["import_payee_name"].present?
          transaction.import_payee_name_original = attributes["import_payee_name_original"] if attributes["import_payee_name_original"].present?

          if attributes["transfer_account_id"].present?
            transfer_account = plan.accounts.not_deleted.find_by(public_id: attributes["transfer_account_id"])
            return render_bad_request("The transfer_account_id is not valid.") if transfer_account.nil?

            transaction.transfer_account = transfer_account
            transaction.payee = transfer_account.transfer_payee
          elsif attributes["payee_id"].present?
            payee = plan.payees.not_deleted.find_by(public_id: attributes["payee_id"])
            return render_bad_request("The payee_id is not valid.") if payee.nil?

            transaction.payee = payee
            transaction.transfer_account = payee.transfer_account
          elsif attributes["payee_name"].present?
            transaction.payee = plan.payees.not_deleted.find_or_create_by!(name: attributes["payee_name"], budget: plan)
            transaction.transfer_account = nil
          elsif attributes.key?("payee_id")
            transaction.payee = nil
            transaction.transfer_account = nil
          end

          if attributes["category_id"].present?
            category = plan.categories.not_deleted.find_by(public_id: attributes["category_id"])
            return render_bad_request("The category_id is not valid.") if category.nil?

            transaction.category = category
          elsif attributes.key?("category_id")
            transaction.category = nil
          end
          true
        end

        def build_sub_transactions(transaction, entries)
          return if entries.blank?

          entries.each do |entry|
            entry = entry.respond_to?(:permit) ? entry.permit!.to_h : entry.to_h
            sub = transaction.sub_transactions.build(amount: entry["amount"], memo: entry["memo"])
            if entry["payee_id"].present?
              sub.payee = plan.payees.not_deleted.find_by(public_id: entry["payee_id"])
            elsif entry["payee_name"].present?
              sub.payee = plan.payees.not_deleted.find_or_create_by!(name: entry["payee_name"], budget: plan)
            end
            sub.category = plan.categories.not_deleted.find_by(public_id: entry["category_id"]) if entry["category_id"].present?
          end
        end

        def rebuild_sub_transactions(transaction, entries)
          return if entries.nil?

          transaction.sub_transactions.each(&:destroy!)
          build_sub_transactions(transaction, entries)
          transaction.sub_transactions.each { |sub| sub.save! if sub.new_record? }
        end

        # Transfers auto-create and sync the paired transaction in the
        # other account (spec: transfer_account_id /
        # transfer_transaction_id).
        def sync_transfer!(transaction)
          transfer_account = transaction.transfer_account
          if transfer_account.nil?
            transaction.transfer_transaction&.update!(transfer_transaction: nil)
            return
          end

          pair = transaction.transfer_transaction ||
            plan.transactions.new(account: transfer_account)
          pair.assign_attributes(
            date: transaction.date,
            amount: -transaction.amount.to_i,
            cleared: transaction.cleared,
            approved: transaction.approved,
            payee: plan.payees.not_deleted.find_by(transfer_account_id: transaction.account.id),
            transfer_account: transaction.account
          )
          pair.save!
          pair.update_columns(transfer_transaction_id: transaction.id) if pair.transfer_transaction_id != transaction.id
          transaction.update_columns(transfer_transaction_id: pair.id) if transaction.transfer_transaction_id != pair.id
        end

        def apply_sub_amounts(sub, sign)
          return if sub.category.nil?

          month_category = sub.category.month_category_for(sub.parent_transaction.month)
          month_category.activity = month_category.activity.to_i + sub.amount.to_i * sign
          month_category.balance = month_category.balance.to_i + sub.amount.to_i * sign
          month_category.save!
        end

        def find_transaction
          transaction = plan.transactions.not_deleted.find_by(public_id: params[:transaction_id])
          render_not_found("No transaction was found with the given id.") if transaction.nil?
          transaction
        end

        def filtered_scope(scope)
          scope = scope.not_deleted.order(:date, :knowledge)
          knowledge = params[:last_knowledge_of_server]
          scope = scope.where(knowledge: (knowledge.to_i + 1)..) if knowledge.present?
          scope = scope.where("date >= ?", Date.iso8601(params[:since_date])) if params[:since_date].present?
          scope = scope.where("date <= ?", Date.iso8601(params[:until_date])) if params[:until_date].present?
          case params[:type]
          when "uncategorized"
            scope = scope.where(category_id: nil)
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
            subs = sub_scope.not_deleted.includes(parent_transaction: [ :account, :budget ])
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
