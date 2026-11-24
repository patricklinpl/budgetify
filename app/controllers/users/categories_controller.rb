module Users
  # Budget grid category actions (issue #56): set Assigned from a typed
  # expression, rename, hide or unhide, and delete with a replacement. The
  # current plan month is the only month shown; month navigation is not built.
  class CategoriesController < ApplicationController
    layout "app_shell"

    before_action :set_budget
    before_action :set_category

    def assign
      parsed = AssignedExpression.parse(params.dig(:assigned, :amount))
      if parsed.error
        return redirect_to(users_budget_path(@budget.public_id), alert: "#{@category.name}: #{parsed.error} Nothing was changed.")
      end

      saved = MonthAssignment.set!(budget: @budget, category: @category, month: Date.current.beginning_of_month, amount: parsed.milliunits, user: Current.user)
      if saved.errors.any?
        redirect_to users_budget_path(@budget.public_id), alert: "#{@category.name}: #{saved.errors.full_messages.to_sentence}. Nothing was changed."
      else
        redirect_to users_budget_path(@budget.public_id), notice: "#{@category.name} assigned #{ActionController::Base.helpers.number_to_currency(parsed.milliunits / 1000.0)}."
      end
    end

    def edit
      @errors = []
      @name = @category.name
      load_removal
    end

    def update
      @name = params.dig(:category, :name).to_s.strip
      @errors = []
      @errors << "Enter a name up to #{PlanLifecycle::MAX_NAME_LENGTH} characters." if @name.empty? || @name.length > PlanLifecycle::MAX_NAME_LENGTH
      hidden = params.dig(:category, :hidden)
      @errors << "Choose whether the category is hidden." unless [ nil, "true", "false" ].include?(hidden)
      if @errors.any?
        load_removal
        return render(:edit, status: :unprocessable_entity)
      end

      attrs = { name: @name }
      attrs[:hidden] = hidden == "true" if hidden
      @category.update!(attrs)
      redirect_to users_budget_path(@budget.public_id), notice: "Category saved."
    end

    def destroy
      replacement = nil
      if params[:replacement_id].present?
        replacement = @budget.categories.find_by(public_id: params[:replacement_id])
        if replacement.nil?
          @errors = [ "Choose a replacement from the list." ]
          @name = @category.name
          load_removal
          return render(:edit, status: :unprocessable_entity)
        end
      end
      CategoryRemoval.delete_category!(@category, replacement: replacement, return_assigned: params[:return_assigned] == "1")
      redirect_to users_budget_path(@budget.public_id), notice: "Category deleted."
    rescue CategoryRemoval::Blocked => e
      @errors = [ e.message ]
      @name = @category.name
      load_removal
      render :edit, status: :unprocessable_entity
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_category
        @category = @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).find_by!(public_id: params[:public_id])
      end

      def load_removal
        @impact = CategoryRemoval.impact([ @category ])
        @replacements = @budget.categories.not_deleted
          .where(internal: false, hidden: false, payment_account_id: nil).where.not(id: @category.id)
          .joins(:category_group).where(category_groups: { hidden: false, deleted: false }).order("category_groups.name, categories.name")
      end
  end
end
