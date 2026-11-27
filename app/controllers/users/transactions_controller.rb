module Users
  # Account register and the ordinary transaction editor (issue #60, slice 2):
  # list, add, edit and delete. Writes go through TransactionWriter, the same
  # code the API uses. Splits are not in this editor. A transfer or card payment
  # is chosen in the Payee field as "To/From <account>" and needs no category.
  # Every lookup is scoped to the current user's plan; other ids are a 404.
  class TransactionsController < ApplicationController
    layout "app_shell"

    TRANSFER_PREFIX = "To/From ".freeze
    # #62 REG-DATE-01 plus the calendar-year presets seen in the reference View menu.
    # The reference also has "Latest 3 Months" and custom From/To months; their exact
    # bounds were not established, so they are not built.
    PERIODS = { "all" => "All dates", "this_month" => "This month", "last_month" => "Last month", "this_year" => "This year", "last_year" => "Last year" }.freeze

    before_action :set_budget
    before_action :set_account
    before_action :set_transaction, only: %i[edit update destroy]

    def index
      scope = @account.transactions.not_deleted.where(budget: @budget)
      # Reconciled rows are hidden by default; showing them only changes the list (#63 REC-01).
      @show_reconciled = params[:reconciled] == "1"
      @hidden_reconciled = @show_reconciled ? 0 : scope.where(cleared: "reconciled").count
      scope = scope.where.not(cleared: "reconciled") unless @show_reconciled
      scope = apply_register_filters(scope)
      @transactions = scope.order(date: :desc, created_at: :desc).includes(:payee, :category)
      # #60 TX-EMPTY-01 / TX-ADD-ANOTHER-01: a row saved without a category is
      # allowed and flagged for categorization. Transfers, splits, inflows (reference
      # behavior for an uncategorized inflow is unverified) and tracking
      # accounts are not flagged. Engineering placement (register note and row cell);
      # the reference's own placement is not verified.
      @needs_category_count = @account.on_budget? ? @account.transactions.not_deleted.where(budget: @budget, category_id: nil, transfer_account_id: nil).where(amount: ..0).where.missing(:sub_transactions).count : 0
    end

    # #62 REG-01 / REG-DATE-01. The search is a plain GET form, so it applies on
    # Enter or the button, never while typing (typing alone did not filter in the
    # reference). [engineering] Case-insensitive substring match on the payee name
    # only: other fields, syntax and combined predicates were not tested. The
    # opening balance row is an ordinary row here and hides when its payee does not
    # match. Filters only change what is listed: balances, the database and the
    # reconciled hiding are untouched, and the number of rows they hide is reported.
    def apply_register_filters(scope)
      @search = params[:q].to_s.strip.first(200)
      @period = PERIODS.key?(params[:period]) ? params[:period] : "all"
      before = scope.count
      range = period_range(@period)
      scope = scope.where(date: range) if range
      if @search.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@search.downcase)}%"
        scope = scope.where(payee_id: @budget.payees.where("lower(payees.name) LIKE ? ESCAPE '\\'", pattern).select(:id))
      end
      @hidden_by_filters = before - scope.count
      @filtered = @search.present? || range.present?
      scope
    end
    private :apply_register_filters

    def period_range(period)
      today = Date.current
      case period
      when "this_month" then today.beginning_of_month..today.end_of_month
      when "last_month" then (today.beginning_of_month - 1.month)..(today.beginning_of_month - 1.day)
      when "this_year" then today.beginning_of_year..today.end_of_year
      when "last_year" then (today.beginning_of_year - 1.year)..(today.beginning_of_year - 1.day)
      end
    end
    private :period_range

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

      announce_undo_notice
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

      # Saving a reconciled row can put the reconciliation out of balance (the
      # reference asks first). Reference checks: a memo-only edit saves without
      # the warning; an amount edit asks. Date, payee and category were not
      # checked, so they keep asking. The first Save writes nothing and shows the
      # warning with the typed values; Cancel on the warning keeps the editor
      # and the values; Save on the warning writes. Status stays reconciled.
      if @transaction.cleared == "reconciled" && params[:confirm_reconciled] != "1" && balance_field_changed?
        @reconciled_warning = params[:confirm_reconciled] != "0"
        return render :edit, status: :unprocessable_entity
      end

      begin
        Transaction.transaction { writer.update!(@transaction, attributes_for(@form).merge(unexposed_attributes), rebuild_subs: false) }
      rescue TransactionWriter::Invalid => e
        @errors = [ e.message ]
        @field_errors = {}
        return render_form(:edit)
      end
      announce_undo_notice
      redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), notice: "Transaction saved."
    end

    def destroy
      if @transaction.cleared == "reconciled" && params[:confirm_reconciled] != "1"
        return render :confirm_delete, status: :unprocessable_entity
      end

      Transaction.transaction { writer.destroy!(@transaction) }
      announce_undo_notice
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
        # A split opens its own editor; saving here would drop it. A linked transfer is edited here
        # through the writer, which keeps the other side in step.
        return unless @transaction.sub_transactions.exists? && action_name != "destroy"

        redirect_to edit_users_budget_account_transaction_split_path(@budget.public_id, @account.public_id, @transaction.public_id)
      end

      def writer
        @writer ||= TransactionWriter.new(@budget, history: undo_history)
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

      # False only for a memo-only edit. Every other field keeps the warning.
      def balance_field_changed?
        stored = form_from_transaction(@transaction)
        return true if %i[date payee category_id].any? { |key| @form[key] != stored[key] }

        @amounts[:inflow].to_i - @amounts[:outflow].to_i != @transaction.amount.to_i
      end

      def stored_form = form_from_transaction(@transaction)
      helper_method :stored_form

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
        errors << "Payee must be 200 characters or fewer." if form[:payee].length > 200
        if form[:payee].downcase.start_with?(TRANSFER_PREFIX.downcase)
          matches = transfer_matches(form)
          errors << "There is no other open account with that name. Choose a To/From entry from the list." if matches.empty?
          errors << "More than one open account has that name, so the transfer would be ambiguous. Rename one of the accounts first." if matches.size > 1
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
            # The category is replaced, as in the reference: a card payment uses
            # the card's Credit Card Payments category, other transfers need none.
            attributes["transfer_account_id"] = target.public_id
            attributes["category_id"] = nil
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
        matches = transfer_matches(form)
        matches.first if matches.one?
      end

      def transfer_matches(form)
        text = form[:payee].to_s
        return [] unless text.downcase.start_with?(TRANSFER_PREFIX.downcase)

        wanted = text[TRANSFER_PREFIX.length..].strip.downcase
        transfer_accounts.select { |account| account.name.downcase == wanted }
      end

      # What the Category field shows for a transfer: the card's payment
      # category (from either side) or "Category not needed".
      def transfer_category_label(target)
        card = [ target, @account ].find(&:credit?)
        card ? "Credit Card Payments: #{card.name}" : "Category not needed"
      end
      helper_method :transfer_category_label

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
