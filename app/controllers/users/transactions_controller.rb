module Users
  # Account register and the ordinary transaction editor (issue #60, slice 2):
  # list, add, edit and delete. Writes go through TransactionWriter, the same
  # code the API uses. Splits are not in this editor. A transfer or card payment
  # is chosen in the Payee field as "To/From <account>" and needs no category.
  # Every lookup is scoped to the current user's plan; other ids are a 404.
  class TransactionsController < ApplicationController
    layout "app_shell"

    TRANSFER_PREFIX = "To/From ".freeze

    before_action :set_budget
    before_action :set_account
    before_action :set_transaction, only: %i[edit update destroy]

    def index
      @transactions = @account.transactions.not_deleted.where(budget: @budget).order(date: :desc, created_at: :desc).includes(:payee, :category)
    end

    def new
      @form = blank_form(date: params[:date])
      @errors = []
      @field_errors = {}
    end

    def create
      @form = form_from_params
      @errors = validate(@form)
      return render_form(:new) if @errors.any? || @field_errors.any?

      begin
        Transaction.transaction { @saved = writer.persist_new!(writer.build(attributes_for(@form).merge("account_id" => @account.public_id))) }
      rescue TransactionWriter::Invalid => e
        @errors = [ e.message ]
        @field_errors = {}
        return render_form(:new)
      end

      if params[:commit_action] == "another"
        redirect_to new_users_budget_account_transaction_path(@budget.public_id, @account.public_id, date: @form[:date]), notice: "Transaction saved."
      else
        redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), notice: "Transaction saved."
      end
    end

    def edit
      @form = form_from_transaction(@transaction)
      @errors = []
      @field_errors = {}
    end

    def update
      @form = form_from_params
      @errors = validate(@form)
      return render_form(:edit) if @errors.any? || @field_errors.any?

      begin
        Transaction.transaction { writer.update!(@transaction, attributes_for(@form).merge(unexposed_attributes), rebuild_subs: false) }
      rescue TransactionWriter::Invalid => e
        @errors = [ e.message ]
        @field_errors = {}
        return render_form(:edit)
      end
      redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), notice: "Transaction saved."
    end

    def destroy
      Transaction.transaction { writer.destroy!(@transaction) }
      redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), notice: "Transaction deleted."
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:account_public_id])
      end

      def set_transaction
        @transaction = @budget.transactions.not_deleted.find_by!(public_id: params[:public_id], account_id: @account.id)
        # A split needs its own editor; saving here would drop it. A linked transfer is edited here
        # through the writer, which keeps the other side in step.
        @unsupported = @transaction.sub_transactions.exists?
        return unless @unsupported && action_name != "destroy"

        redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), alert: "This transaction is a split. This editor does not handle splits yet, so nothing was changed."
      end

      def writer
        @writer ||= TransactionWriter.new(@budget)
      end

      def render_form(template)
        render template, status: :unprocessable_entity
      end

      def blank_form(date: nil)
        { date: valid_date_text(date) || Date.current.iso8601, payee: "", category_id: "", memo: "", outflow: "", inflow: "" }
      end

      def valid_date_text(text)
        Date.iso8601(text.to_s).iso8601
      rescue ArgumentError, TypeError
        nil
      end

      def form_from_params
        raw = params[:transaction]
        raw = raw.is_a?(ActionController::Parameters) ? raw.permit(:date, :payee, :category_id, :memo, :outflow, :inflow) : ActionController::Parameters.new.permit
        { date: raw[:date].to_s, payee: raw[:payee].to_s.strip, category_id: raw[:category_id].to_s, memo: raw[:memo].to_s, outflow: raw[:outflow].to_s.strip, inflow: raw[:inflow].to_s.strip }
      end

      def form_from_transaction(transaction)
        amount = transaction.amount.to_i
        {
          date: transaction.date.iso8601, payee: transaction.transfer_account ? "#{TRANSFER_PREFIX}#{transaction.transfer_account.name}" : transaction.payee&.name.to_s, category_id: transaction.category&.public_id.to_s, memo: transaction.memo.to_s,
          outflow: amount.negative? ? plain_money(-amount) : "", inflow: amount.positive? ? plain_money(amount) : ""
        }
      end

      def plain_money(milliunits)
        format("%.2f", milliunits / 1000.0)
      end

      # Field-level errors are kept in @field_errors by key; the returned list
      # is for everything else. Nothing is saved while either has an entry.
      def validate(form)
        @field_errors = {}
        errors = []
        errors << "Enter a date." if form[:date].blank?
        @amounts = {}
        %i[outflow inflow].each do |key|
          next if form[key].blank?

          parsed = AssignedExpression.parse(form[key])
          if parsed.error
            @field_errors[key] = parsed.error
          elsif parsed.milliunits.negative?
            @field_errors[key] = "Enter a positive amount"
          else
            @amounts[key] = parsed.milliunits
          end
        end
        errors << "Enter an outflow or an inflow, not both." if form[:outflow].present? && form[:inflow].present?
        errors << "Choose a category from the list." if form[:category_id].present? && category_options.none? { |category| category.public_id == form[:category_id] }
        errors << "A transfer or card payment does not use a category. Clear the category or choose a payee instead." if transfer_target(form) && form[:category_id].present?
        errors << "Payee must be 200 characters or fewer." if form[:payee].length > 200
        # The writer rejects other names with an exception (a 500 here before this check).
        if form[:payee].present? && transfer_target(form).nil?
          if form[:payee].downcase.start_with?(TRANSFER_PREFIX.downcase)
            errors << "There is no other open account with that name. Choose a To/From entry from the list."
          elsif !Payee::NAME_FORMAT.match?(form[:payee])
            errors << "Payee may only contain letters, numbers and spaces."
          end
        end
        errors
      end

      def attributes_for(form)
        outflow = @amounts[:outflow].to_i
        inflow = @amounts[:inflow].to_i
        {
          "date" => form[:date], "amount" => inflow - outflow, "memo" => form[:memo], "payee_name" => form[:payee].presence,
          "category_id" => form[:category_id].presence
        }.tap do |attributes|
          if (target = transfer_target(form))
            attributes["transfer_account_id"] = target.public_id
            attributes.delete("payee_name")
          end
          # Editing: an emptied payee or category clears it.
          attributes["payee_id"] = nil if form[:payee].blank?
          attributes.delete("payee_name") if form[:payee].blank?
          attributes["category_id"] = nil if form[:category_id].blank?
        end
      end

      # The editor has no flag fields. The writer assigns flags unconditionally
      # (API semantics), so an edit here passes the stored values back to keep
      # them instead of clearing them.
      def unexposed_attributes
        { "flag_color" => @transaction.flag_color, "flag_name" => @transaction.flag_name }
      end

      # "To/From <account>" names another open account of this plan. Text that
      # starts with "To/From " and names none is refused, not saved as a payee.
      def transfer_target(form)
        text = form[:payee].to_s
        return unless text.downcase.start_with?(TRANSFER_PREFIX.downcase)

        wanted = text[TRANSFER_PREFIX.length..].strip.downcase
        transfer_accounts.find { |account| account.name.downcase == wanted }
      end

      def transfer_accounts
        @transfer_accounts ||= @budget.accounts.not_deleted.where.not(id: @account.id).order(:name).to_a
      end
      helper_method :transfer_accounts

      def category_options
        @category_options ||= @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).order(:name).to_a
      end
      helper_method :category_options
  end
end
