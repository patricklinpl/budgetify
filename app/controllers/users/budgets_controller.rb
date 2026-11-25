module Users
  # Plan list, plan creation, plan settings and Fresh Start (issue #54).
  # Plans are private to their owner: every lookup is scoped to the current
  # user, and nothing here shares a plan.
  class BudgetsController < ApplicationController
    layout "app_shell", only: %i[show settings update fresh_start moves]

    before_action :set_budget, only: %i[show settings update fresh_start moves]

    def index
      @budgets = Current.user.budgets.order(:name)
    end

    def show
      # Selected account is shell state carried in the URL so it survives Turbo
      # navigation. Scoped to this plan; unknown ids are a 404.
      if params[:account].present?
        @selected_account = @budget.accounts.not_deleted.find_by!(public_id: params[:account])
      else
        load_grid
      end
    end

    # Recent Moves (#57 MONEY-03): a read-only list of this plan's money
    # movements, newest first. The reference tabs and actor filter were only
    # inspected (predicates unknown), so none are built here.
    def moves
      scope = @budget.money_movements.not_deleted
      @moves_total = scope.count
      @moves = scope.includes(:from_category, :to_category, :performed_by_user)
        .order(moved_at: :desc, id: :desc).limit(100)
    end

    def create
      name = PlanLifecycle.clean_name(budget_params[:name])
      if name
        created = PlanLifecycle.create_plan(Current.user, name: name)
        redirect_to users_budget_path(created.public_id), notice: "Plan created."
      else
        @budgets = Current.user.budgets.order(:name)
        @new_plan_name = budget_params[:name].to_s.strip
        @new_plan_error = name_error
        render :index, status: :unprocessable_entity
      end
    end

    def settings
      @form = form_from_budget
      @errors = []
    end

    # Saves the name and formats together or not at all. Cancel on the page
    # is a plain link back to the plan, so nothing is saved.
    def update
      attrs = budget_params.permit(:name, :date_format, currency_format: {})
      @form = form_from_params(attrs)
      @errors = []
      @errors << name_error unless PlanLifecycle.clean_name(@form[:name])
      @errors << "Choose a supported date format." unless PlanLifecycle::DATE_FORMATS.include?(@form[:date_format])
      format, format_errors = CurrencyFormat.build(typed_currency_values(@form[:currency_format]), base: @budget.currency_format)
      @errors.concat(format_errors)

      if @errors.empty?
        @budget.update!(name: PlanLifecycle.clean_name(@form[:name]), date_format: @form[:date_format], currency_format: format.storage_json)
        redirect_to settings_users_budget_path(@budget.public_id), notice: "Plan settings saved."
      else
        render :settings, status: :unprocessable_entity
      end
    end

    def fresh_start
      fresh = PlanLifecycle.fresh_start(@budget)
      redirect_to users_budget_path(fresh.public_id),
        notice: "Fresh Start created a new plan. The original is kept as #{@budget.reload.name}."
    rescue PlanLifecycle::UnsupportedCarry => e
      @form = form_from_budget
      @errors = [ "Fresh Start was not run, and nothing changed. #{e.blockers.size} scheduled transaction(s) use a deleted account or a deleted category and cannot carry over unchanged. Fix or delete them first." ]
      render :settings, status: :unprocessable_entity
    end

    private
      def load_grid
        @show_hidden = params[:hidden] == "1"
        @grid, @hidden_count = PlanGrid.build(@budget, show_hidden: @show_hidden)
        @filter = PlanGrid::FILTERS.key?(params[:filter]) ? params[:filter] : "all"
        @filtered_out = 0
        @grid, @filtered_out = PlanGrid.filter(@grid, @filter) unless @filter == "all"
      end

      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:public_id])
      end

      def budget_params
        raw = params[:budget]
        raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new
      end

      def name_error
        "Enter a plan name of up to #{PlanLifecycle::MAX_NAME_LENGTH} characters."
      end

      def form_from_budget
        { name: @budget.name, date_format: @budget.date_format, currency_format: @budget.currency_format.storage_json.except("example_format") }
      end

      def form_from_params(attrs)
        { name: attrs[:name].to_s.strip, date_format: attrs[:date_format].to_s,
          currency_format: attrs[:currency_format].respond_to?(:to_h) ? attrs[:currency_format].to_h : {} }
      end

      # Form fields arrive as strings; convert only values that parse so
      # anything else reaches the same validation as the API and is rejected.
      def typed_currency_values(values)
        values = values.to_h.stringify_keys
        values["decimal_digits"] = Integer(values["decimal_digits"], 10) if values["decimal_digits"].to_s.match?(/\A\d+\z/)
        %w[symbol_first display_symbol].each do |key|
          values[key] = values[key] == "true" if %w[true false].include?(values[key])
        end
        values
      end
  end
end
