module Users
  # Split editor for one transaction (issue #60, slice 3): the parent total and
  # child rows (category, memo, outflow or inflow each, so mixed signs work).
  # Saving needs the children to add up to the total. When they do not, the
  # editor shows the mismatch and saves nothing; "Update Total" sets the total
  # to the children's sum in the form, and "Adjust Manually" returns to the
  # editor with the values kept (audit TX-SPLIT-01 to 04). Auto-Distribute and
  # split-transfer children are not built (see the PR). Writes go through
  # TransactionWriter; effects follow the writer: the account moves by the
  # parent once, each child moves its own category.
  class TransactionSplitsController < ApplicationController
    layout "app_shell"

    EXTRA_ROWS = 2
    MAX_ROWS = 30

    before_action :set_budget
    before_action :set_account
    before_action :set_transaction

    def edit
      @total = money_pair(@transaction.amount.to_i)
      @rows = @transaction.sub_transactions.not_deleted.order(:id).map { |sub| row_from(sub) }
      @rows.concat(Array.new(EXTRA_ROWS) { blank_row }) if @rows.size < 2
      @field_errors = {}
      @row_errors = {}
      @errors = []
      @mismatch = nil
    end

    def update
      read_form
      action = params[:split_action].to_s
      return rerender(:unprocessable_entity) if @errors.any? || @field_errors.any? || @row_errors.any?

      case action
      when "add_row"
        @rows << blank_row if @rows.size < MAX_ROWS
        @notice = "Row added. Nothing is saved until you press Save."
        rerender(:ok)
      when "update_total"
        @total = money_pair(sum_of_rows)
        @notice = "Total set to the split rows' sum. Nothing is saved until you press Save."
        rerender(:ok)
      when "adjust"
        @notice = "Back in the editor with your values kept. Nothing is saved yet."
        rerender(:ok)
      else
        save
      end
    end

    private
      def save
        entries = filled_rows
        return fail_with("Add at least one split row.") if entries.empty?

        total = parsed_total
        children = sum_of_rows
        if total != children
          @mismatch = { total: total, children: children, remainder: total - children }
          return rerender(:unprocessable_entity)
        end

        # Reference checks: changing the parent total on a reconciled split
        # warns; memo-only edits and moving amounts between children at the
        # same total do not. Mismatch and input errors are refused above first.
        if @transaction.cleared == "reconciled" && params[:confirm_reconciled] != "1" && total != @transaction.amount.to_i
          @reconciled_warning = params[:confirm_reconciled] != "0"
          return rerender(:unprocessable_entity)
        end

        begin
          Transaction.transaction { writer.update!(@transaction, attributes_for(total, entries), rebuild_subs: true) }
        rescue TransactionWriter::Invalid => e
          return fail_with(e.message)
        end
        announce_undo_notice
        register_path = users_budget_account_transactions_path(@budget.public_id, @account.public_id)
        keep_undo_history_for(register_path)
        redirect_to register_path, notice: "Split saved."
      end

      def attributes_for(total, entries)
        {
          "amount" => total, "category_id" => nil,
          "flag_color" => @transaction.flag_color, "flag_name" => @transaction.flag_name,
          "subtransactions" => entries.map { |row| { "amount" => row[:amount], "category_id" => row[:category_id].presence, "memo" => row[:memo] } }
        }
      end

      def fail_with(message)
        @errors << message
        rerender(:unprocessable_entity)
      end

      def rerender(status)
        @total ||= money_pair(0)
        render :edit, status: status
      end

      def read_form
        @errors = []
        @field_errors = {}
        @row_errors = {}
        @mismatch = nil
        raw = params[:split].is_a?(ActionController::Parameters) ? params[:split] : ActionController::Parameters.new
        @total = { outflow: raw[:outflow].to_s.strip, inflow: raw[:inflow].to_s.strip }
        @total_parsed = parse_pair(@total, @field_errors, :total)
        @errors << "Enter a total outflow or inflow, not both." if @total[:outflow].present? && @total[:inflow].present?
        @errors << "Enter a total." if @total[:outflow].blank? && @total[:inflow].blank? && @field_errors.empty?

        rows = raw[:rows].respond_to?(:values) ? raw[:rows].values : []
        @rows = rows.first(MAX_ROWS).map do |entry|
          entry = entry.permit(:category_id, :memo, :outflow, :inflow)
          { category_id: entry[:category_id].to_s, memo: entry[:memo].to_s, outflow: entry[:outflow].to_s.strip, inflow: entry[:inflow].to_s.strip }
        end
        @rows.each_with_index do |row, index|
          errors = {}
          row[:amount] = parse_pair(row, errors, :row)
          if row[:outflow].present? && row[:inflow].present?
            (@row_errors[index] ||= []) << "Enter an outflow or an inflow, not both."
          end
          if row[:category_id].present? && category_options.none? { |category| category.public_id == row[:category_id] }
            (@row_errors[index] ||= []) << "Choose a category from the list."
          end
          if !blank_row?(row) && row[:outflow].blank? && row[:inflow].blank?
            (@row_errors[index] ||= []) << "Enter an amount, or clear this row."
          end
          row[:field_errors] = errors
          (@row_errors[index] ||= []) << errors.values.first if errors.any?
        end
      end

      def parse_pair(source, errors, _scope)
        value = nil
        %i[outflow inflow].each do |key|
          next if source[key].blank?

          parsed = AssignedExpression.parse(source[key])
          if parsed.error
            errors[key] = parsed.error
          elsif parsed.milliunits.negative?
            errors[key] = "Enter a positive amount"
          else
            value = (key == :inflow ? parsed.milliunits : -parsed.milliunits)
          end
        end
        value
      end

      def parsed_total
        @total_parsed.to_i
      end

      def filled_rows
        @rows.reject { |row| blank_row?(row) }
      end

      def sum_of_rows
        filled_rows.sum { |row| row[:amount].to_i }
      end

      def blank_row?(row)
        row[:category_id].blank? && row[:memo].blank? && row[:outflow].blank? && row[:inflow].blank?
      end

      def blank_row
        { category_id: "", memo: "", outflow: "", inflow: "", field_errors: {} }
      end

      def row_from(sub)
        { category_id: sub.category&.public_id.to_s, memo: sub.memo.to_s, field_errors: {} }.merge(money_pair(sub.amount.to_i))
      end

      def money_pair(milliunits)
        { outflow: milliunits.negative? ? plain_money(-milliunits) : "", inflow: milliunits.positive? ? plain_money(milliunits) : "" }
      end

      def plain_money(milliunits)
        format("%.2f", milliunits / 1000.0)
      end

      def stored_total = money_pair(@transaction.amount.to_i)
      helper_method :stored_total

      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:account_public_id])
      end

      def set_transaction
        @transaction = @budget.transactions.not_deleted.find_by!(public_id: params[:transaction_public_id], account_id: @account.id)
        return unless @transaction.transfer_account_id.present?

        redirect_to users_budget_account_transactions_path(@budget.public_id, @account.public_id), alert: "Split transfers are not built yet, so this transfer cannot be split. Nothing was changed."
      end

      def writer
        @writer ||= TransactionWriter.new(@budget, history: undo_history)
      end

      def category_options
        @category_options ||= @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).order(:name).to_a
      end
      helper_method :category_options

      def milliunits_text(value)
        amount = value.to_i
        format("%s$%.2f", amount.negative? ? "-" : "", amount.abs / 1000.0)
      end
      helper_method :milliunits_text
  end
end
