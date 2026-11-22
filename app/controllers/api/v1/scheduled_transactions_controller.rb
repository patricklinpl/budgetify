module Api
  module V1
    # YNAB scheduled transaction endpoints (spec:
    # ScheduledTransactionsResponse, ScheduledTransactionResponse). Nested
    # under /v1/plans/:plan_id.
    class ScheduledTransactionsController < BaseController
      before_action :set_plan

      # GET /v1/plans/:plan_id/scheduled_transactions - detail list +
      # server_knowledge, with last_knowledge_of_server delta (spec:
      # getScheduledTransactions).
      def index
        scope = delta_scope(plan.scheduled_transactions).order(:date_next, :knowledge)
        scope = scope.includes(:account, :payee, :category, :transfer_account, :scheduled_sub_transactions)
        render_data({ scheduled_transactions: scope.map { |scheduled| ScheduledTransactionSerializer.detail_as_json(scheduled) } }, server_knowledge: plan.server_knowledge)
      end

      # POST /v1/plans/:plan_id/scheduled_transactions - create one
      # scheduled transaction (spec: PostScheduledTransactionWrapper /
      # SaveScheduledTransaction). date must be a future date.
      def create
        attributes = permitted_params
        return if attributes.nil?

        scheduled = plan.scheduled_transactions.new
        return unless save_scheduled(scheduled, attributes)

        render_data({ scheduled_transaction: ScheduledTransactionSerializer.detail_as_json(scheduled) }, status: :created)
      end

      # GET /v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id
      # (spec: getScheduledTransactionById).
      def show
        scheduled = find_scheduled
        return if scheduled.nil?

        render_data({ scheduled_transaction: ScheduledTransactionSerializer.detail_as_json(scheduled) })
      end

      # PUT /v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id
      # (spec: PutScheduledTransactionWrapper / SaveScheduledTransaction).
      def update
        scheduled = find_scheduled
        return if scheduled.nil?

        attributes = permitted_params
        return if attributes.nil?

        return unless save_scheduled(scheduled, attributes)

        render_data({ scheduled_transaction: ScheduledTransactionSerializer.detail_as_json(scheduled) })
      end

      # DELETE /v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id
      # - soft delete; tombstones appear only in delta requests (spec:
      # deleteScheduledTransaction).
      def destroy
        scheduled = find_scheduled
        return if scheduled.nil?

        scheduled.update!(deleted: true)
        render_data({ scheduled_transaction: ScheduledTransactionSerializer.detail_as_json(scheduled) })
      end

      private
        # Payee creation and schedule edits are one write. A later
        # validation error must not leave an orphan payee or partial edit.
        def save_scheduled(scheduled, attributes)
          ScheduledTransaction.transaction do
            raise ActiveRecord::Rollback unless assign_attributes_for(scheduled, attributes)
            unless scheduled.date_next && scheduled.date_next > Date.current
              render_bad_request("The scheduled transaction date must be in the future.")
              raise ActiveRecord::Rollback
            end
            unless scheduled.save
              render_bad_request(scheduled.errors.full_messages.to_sentence)
              raise ActiveRecord::Rollback
            end
            true
          end
        end

        def find_scheduled
          scheduled = plan.scheduled_transactions.not_deleted.find_by(public_id: params[:scheduled_transaction_id])
          render_not_found("No scheduled transaction was found with the given id.") if scheduled.nil?
          scheduled
        end

        def permitted_params
          source = params.require(:scheduled_transaction)
          return render_bad_request("Creating split scheduled transactions is not supported.") if source.key?(:subtransactions)
          return render_bad_request("The payee_name must be at most 200 characters.") if source[:payee_name].to_s.length > 200
          source.permit(
            :account_id, :date, :amount, :payee_id, :payee_name, :category_id,
            :memo, :flag_color, :flag_name, :frequency, :transfer_account_id
          ).to_h
        rescue ActionController::ParameterMissing
          render_bad_request("Request body must include a scheduled_transaction object.")
          nil
        end

        # Assigns SaveScheduledTransaction input. date maps to date_first;
        # date_next is recomputed from date_first and frequency (spec:
        # ScheduledTransactionSummary.date_next).
        def assign_attributes_for(scheduled, attributes)
          return render_bad_request("The account_id and date are required.") if attributes["account_id"].blank? || attributes["date"].blank?
          if attributes["account_id"].present?
            account = plan.accounts.not_deleted.find_by(public_id: attributes["account_id"])
            return render_bad_request("The account_id is not valid.") if account.nil?

            scheduled.account = account
          end

          if attributes["date"].present?
            date = begin
              Date.iso8601(attributes["date"].to_s)
            rescue ArgumentError, TypeError
              return render_bad_request("The date is not valid; use ISO format (e.g. 2016-12-01).")
            end
            return render_bad_request("The date must be in the future and no more than five years ahead.") unless date > Date.current && date <= Date.current.advance(years: 5)
            scheduled.date_first = date
          end

          scheduled.amount = attributes["amount"] if attributes.key?("amount") && !attributes["amount"].nil?
          scheduled.memo = attributes["memo"] if attributes.key?("memo")
          scheduled.flag_color = attributes["flag_color"].presence if attributes.key?("flag_color")
          scheduled.flag_name = attributes["flag_name"] if attributes.key?("flag_name")
          scheduled.frequency = attributes["frequency"] if attributes["frequency"].present?

          if attributes["transfer_account_id"].present?
            transfer_account = plan.accounts.not_deleted.find_by(public_id: attributes["transfer_account_id"])
            return render_bad_request("The transfer_account_id is not valid.") if transfer_account.nil?

            scheduled.transfer_account = transfer_account
            scheduled.payee = transfer_account.transfer_payee
          elsif attributes["payee_id"].present?
            payee = plan.payees.not_deleted.find_by(public_id: attributes["payee_id"])
            return render_bad_request("The payee_id is not valid.") if payee.nil?

            scheduled.payee = payee
            scheduled.transfer_account = payee.transfer_account
          elsif attributes["payee_name"].present?
            scheduled.payee = plan.payees.not_deleted.find_or_create_by!(name: attributes["payee_name"], budget: plan)
            scheduled.transfer_account = nil
          elsif attributes.key?("payee_id")
            scheduled.payee = nil
            scheduled.transfer_account = nil
          end

          if attributes["category_id"].present?
            category = plan.categories.not_deleted.find_by(public_id: attributes["category_id"])
            return render_bad_request("The category_id is not valid.") if category.nil?

            return render_bad_request("Credit Card Payment categories are not permitted.") if category.payment?
            scheduled.category = category
          elsif attributes.key?("category_id")
            scheduled.category = nil
          end

          scheduled.recompute_date_next!
          true
        end

        def render_not_found(detail)
          render_api_error(:not_found, detail, id: "404.2", name: "resource_not_found")
          nil
        end

        def render_bad_request(detail)
          render_api_error(:bad_request, detail, id: "400", name: "bad_request")
          nil
        end
    end
  end
end
