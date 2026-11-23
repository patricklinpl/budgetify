module Users
  # Account add and edit pages in the app shell (issue #55). Every lookup is
  # scoped to the current user's plan; other users' ids are a 404.
  class AccountsController < ApplicationController
    layout "app_shell"

    before_action :set_budget
    before_action :set_account, only: %i[edit update destroy close reopen adjust]

    BALANCE_PATTERN = /\A-?\d{1,12}(\.\d{1,3})?\z/

    # Types offered on the form. Loan types have no tested setup yet, so they
    # are listed as unavailable instead of silently missing.
    TYPE_OPTIONS = [
      [ "Checking", "checking" ], [ "Savings", "savings" ], [ "Cash", "cash" ],
      [ "Credit Card", "creditCard" ], [ "Line of Credit", "lineOfCredit" ],
      [ "Asset (tracking)", "otherAsset" ], [ "Liability (tracking)", "otherLiability" ]
    ].freeze
    UNAVAILABLE_TYPES = [ "Mortgage", "Auto Loan", "Student Loan", "Personal Loan", "Medical Debt", "Other Debt" ].freeze

    def new
      @form = { name: "", type: "", balance: "" }
      @errors = []
    end

    def create
      attrs = account_params
      @form = { name: attrs[:name].to_s.strip, type: attrs[:type].to_s, balance: attrs[:balance].to_s.strip }
      @errors = validate_new(@form)
      return render(:new, status: :unprocessable_entity) if @errors.any?

      account = Account.open!(budget: @budget, attributes: { "name" => @form[:name], "type" => @form[:type], "balance" => to_milliunits(@form[:balance]) })
      redirect_to users_budget_path(@budget.public_id, account: account.public_id), notice: "Account added."
    rescue ActiveRecord::RecordInvalid => e
      @errors = [ e.record.errors.full_messages.to_sentence ]
      render :new, status: :unprocessable_entity
    end

    def edit
      @form = { name: @account.name, note: @account.note.to_s }
      @errors = []
    end

    def update
      attrs = params[:account].is_a?(ActionController::Parameters) ? params[:account].permit(:name, :note) : ActionController::Parameters.new.permit
      @form = { name: attrs[:name].to_s.strip, note: attrs[:note].to_s }
      @errors = []
      @errors << name_error unless PlanLifecycle.clean_name(@form[:name])
      @errors << "The note can be up to 2000 characters." if @form[:note].length > 2000
      return render(:edit, status: :unprocessable_entity) if @errors.any?

      @account.update!(name: @form[:name], note: @form[:note].presence)
      redirect_to users_budget_path(@budget.public_id, account: @account.public_id), notice: "Account saved."
    end

    def close
      @account.close!
      redirect_to edit_users_budget_account_path(@budget.public_id, @account.public_id), notice: "Account closed."
    rescue Account::Blocked => e
      @form = { name: @account.name, note: @account.note.to_s }
      @errors = [ e.message ]
      render :edit, status: :unprocessable_entity
    end

    def reopen
      @account.reopen!
      redirect_to edit_users_budget_account_path(@budget.public_id, @account.public_id), notice: "Account reopened at zero."
    end

    # Manual Balance Adjustment (TRACK-01): tracking accounts only. On-budget
    # adjustment has no tested reference behavior and is refused with a reason.
    def adjust
      text = params.dig(:adjustment, :balance).to_s.strip
      unless text.match?(BALANCE_PATTERN)
        @form = { name: @account.name, note: @account.note.to_s }
        @errors = [ "Enter the new balance as a number such as 1000.00 or -50.25." ]
        return render(:edit, status: :unprocessable_entity)
      end

      @account.adjust_balance!(to_milliunits(text))
      redirect_to users_budget_path(@budget.public_id, account: @account.public_id), notice: "Balance adjusted."
    rescue Account::Blocked => e
      @form = { name: @account.name, note: @account.note.to_s }
      @errors = [ e.message ]
      render :edit, status: :unprocessable_entity
    end

    def destroy
      @account.delete_opening_only!
      redirect_to users_budget_path(@budget.public_id), notice: "Account deleted."
    rescue Account::Blocked => e
      @form = { name: @account.name, note: @account.note.to_s }
      @errors = [ e.message ]
      render :edit, status: :unprocessable_entity
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:public_id])
      end

      def account_params
        raw = params[:account]
        raw.is_a?(ActionController::Parameters) ? raw.permit(:name, :type, :balance) : ActionController::Parameters.new.permit
      end

      def validate_new(form)
        errors = []
        errors << name_error unless PlanLifecycle.clean_name(form[:name])
        errors << "Choose an account type." unless Account::SAVE_TYPES.include?(form[:type])
        errors << "Enter the current balance as a number such as 1000.00 or -50.25." unless form[:balance].match?(BALANCE_PATTERN)
        errors
      end

      def name_error
        "Enter an account name of up to #{PlanLifecycle::MAX_NAME_LENGTH} characters, without control characters."
      end

      def to_milliunits(text)
        (BigDecimal(text) * 1000).to_i
      end
  end
end
