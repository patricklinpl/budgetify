module Users
  # Confirm step of a CSV import: writes the rows the preview showed as new or
  # matched, as one Undo step. The file comes from the stored draft, not from
  # the request. Every lookup is scoped to the current user's plan; other ids
  # are a 404. A refusal changes nothing and says why.
  class ImportConfirmsController < ApplicationController
    before_action :set_budget
    before_action :set_account

    def create
      register_path = users_budget_account_transactions_path(@budget.public_id, @account.public_id)
      draft = ImportDraft.where(user: Current.user, budget: @budget, account: @account).find_by(token: params[:draft].to_s)
      if draft.nil?
        return redirect_to register_path, alert: CsvImportCommit::ALREADY
      end

      outcome = CsvImportCommit.new(budget: @budget, account: @account, draft: draft, user: Current.user, history: undo_history, digest: params[:digest]).call
      announce_undo_notice
      keep_undo_history_for(register_path)
      redirect_to register_path, notice: "Imported #{outcome.created} new and #{outcome.matched} matched transactions (#{outcome.skipped} skipped). Undo reverses the whole import."
    rescue CsvImportCommit::Refused => e
      redirect_to register_path, alert: e.message
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:account_public_id])
      end
  end
end
