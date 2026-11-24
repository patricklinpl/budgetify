module Users
  # Reconcile an account (#63 REC-01 to REC-03). The page asks whether the
  # account balance matches the cleared balance. Yes marks the cleared rows
  # reconciled. No takes the statement balance, shows the difference and, on the
  # second step, records one adjustment and marks the rows. Invalid text is kept
  # with an error and nothing changes. Every lookup is scoped to the current
  # user's plan; other ids are a 404. Undo and the reconciled-edit warnings
  # (REC-04, REC-05) are not built.
  class ReconciliationsController < ApplicationController
    layout "app_shell"

    before_action :set_budget
    before_action :set_account

    def show
      @entered = ""
      @errors = []
      @review = nil
    end

    def create
      return refuse("This account is closed. Reopen it before reconciling.") if @account.closed?

      if params[:answer] == "yes"
        return finish { @account.reconcile! }
      end

      @entered = params[:balance].to_s.strip
      parsed = AssignedExpression.parse(@entered)
      return fail_with([ parsed.error ]) if parsed.error

      @review = { entered: parsed.milliunits, difference: parsed.milliunits - @account.cleared_balance }
      return finish { @account.reconcile!(entered: parsed.milliunits) } if params[:step] == "finish"

      @errors = []
      render :show
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:account_public_id])
      end

      def finish
        result = yield
        notice = if result.adjustment
          "Reconciled. One adjustment of #{milliunits_text(result.difference)} was recorded."
        else
          "Reconciled."
        end
        redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), notice: notice
      rescue Account::Blocked => e
        refuse(e.message)
      end

      def refuse(message)
        fail_with([ message ])
      end

      def fail_with(errors)
        @errors = errors
        @entered ||= ""
        @review = nil
        render :show, status: :unprocessable_entity
      end

      def milliunits_text(value)
        amount = value.to_i
        format("%s$%.2f", amount.negative? ? "-" : "", amount.abs / 1000.0)
      end
      helper_method :milliunits_text
  end
end
