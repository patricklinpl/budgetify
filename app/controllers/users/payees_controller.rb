module Users
  # Payees manager (#65 PAYEE-01, partial): list the plan's payees and rename one
  # with an explicit Save button. [engineering] The reference showed typing and
  # then Done did not commit, and the audit asks for a clear commit affordance, so
  # each row is a form with a Save button and Enter submits it too.
  # Transfer payees belong to their account and are not listed or editable. A
  # duplicate name (case-insensitive, within the plan) is rejected by the model
  # and nothing is written. Combine, hide and unhide are not built.
  class PayeesController < ApplicationController
    layout "app_shell"

    before_action :set_budget

    def index
      load_payees
    end

    def update
      payee = payees.find_by!(public_id: params[:public_id])
      name = params.dig(:payee, :name).to_s.strip
      payee.name = name
      if payee.valid?
        payee.save!
        redirect_to users_budget_payees_path(@budget.public_id), notice: "Payee renamed to #{payee.name}."
      else
        load_payees
        @error = { id: payee.public_id, text: name, message: "#{payee.errors.full_messages.to_sentence}." }
        render :index, status: :unprocessable_entity
      end
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def payees
        @budget.payees.not_deleted.where(transfer_account_id: nil)
      end

      def load_payees
        @payees = payees.order(Arel.sql("LOWER(name)"), :id).to_a
      end
  end
end
