module Users
  # Reflect (#64 slice 2): Spending Breakdown. Read-only and server-rendered; all
  # numbers come from ReportQuery. Lookups are scoped to the current user's plan,
  # and ids that are not in this plan are ignored, never an error. Bad month
  # params fall back to the default month [engineering]. Trends, Income v
  # Expense, Net Worth and Age of Money are not built yet.
  class ReflectController < ApplicationController
    layout "app_shell"

    before_action :set_budget

    def show
      @today = Date.current.beginning_of_month
      @start_month, @end_month = month_range
      @last3_start = last_three_months_start
      @by = params[:by] == "groups" ? "groups" : "categories"
      @accounts = @budget.accounts.not_deleted.where(on_budget: true).order(:name)
      @category_options = @budget.categories.not_deleted.joins(:category_group)
        .where(internal: false, payment_account_id: nil).order("category_groups.name", :name)
      @account_filter = @accounts.where(public_id: Array(params[:accounts])).to_a
      @category_filter = @category_options.where(public_id: Array(params[:categories])).to_a
      @report = ReportQuery.new(@budget, start_month: @start_month, end_month: @end_month,
        account_ids: (@account_filter.map(&:id) if @account_filter.any?),
        category_ids: (@category_filter.map(&:id) if @category_filter.any?))
      @slices = build_slices
      @drill = @slices.find { |slice| slice[:key] == params[:drill] }
      @drill_rows = @drill ? @drill[:rows].sort_by { |row| [ row.date, row.transaction.id ] } : []
      @fmt = @budget.currency_format
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def month_range
        start = parse_month(params[:start]) || @today
        finish = parse_month(params[:end]) || start
        finish < start ? [ @today, @today ] : [ start, finish ]
      end

      # "Last 3 months" [engineering rule, pinned]: from the earliest month that has
      # a non-deleted, non-opening-balance transaction on an on-budget account,
      # but no earlier than two months before this month, through this month.
      # The audit shows Oct-Nov, not three artificial months; it does not say how
      # opening balances or tracking rows anchor "data", so this rule is ours.
      # The chosen range lives in the URL, so it stays after a row is deleted.
      def last_three_months_start
        earliest = @budget.transactions.not_deleted.where(opening_balance: false)
          .where(account_id: @budget.accounts.where(on_budget: true).select(:id)).minimum(:date)
        floor = @today << 2
        earliest ? [ earliest.beginning_of_month, floor ].max : @today
      end

      def parse_month(text)
        return nil unless text.to_s.match?(/\A\d{4}-\d{2}\z/)
        Date.strptime(text, "%Y-%m")
      rescue ArgumentError
        nil
      end

      # One slice per category (or per group), largest first, ties by name
      # [engineering]. Percent shares use ReportQuery::Rounding.
      def build_slices
        rows = @report.spending_rows
        grouped = if @by == "groups"
          rows.group_by { |row| row.category.category_group }
        else
          rows.group_by(&:category)
        end
        # A category or group whose refunds exceed its spending nets below zero.
        # Shares and the donut use only net-spending slices over their own sum,
        # so no share passes 100 percent and no gradient stop is negative; a
        # net-refund slice stays in the table with no share [engineering].
        sums = grouped.transform_values { |slice_rows| slice_rows.sum(&:amount) }
        @chart_total = sums.values.select(&:positive?).sum
        grouped.map do |record, slice_rows|
          amount = sums.fetch(record)
          { key: record.public_id, name: record.name, amount: amount, count: slice_rows.size, rows: slice_rows,
            percent: (amount.positive? ? ReportQuery::Rounding.percent_tenths(amount, @chart_total) : nil) }
        end.sort_by { |slice| [ -slice[:amount], slice[:name] ] }
      end
  end
end
