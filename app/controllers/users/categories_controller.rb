module Users
  # Budget grid category actions (issue #56): set Assigned from a typed
  # expression, rename, hide or unhide, and delete with a replacement. The
  # current plan month is the only month shown; month navigation is not built.
  class CategoriesController < ApplicationController
    layout "app_shell"

    before_action :set_budget
    before_action :set_category

    # Assigned from the grid. A rejected expression re-renders the plan page
    # with the typed text kept in that row's field and an inline error, and
    # saves nothing (FRM-02, FRM-05).
    def assign
      text = params.dig(:assigned, :amount).to_s
      parsed = AssignedExpression.parse(text)
      return render_assign_error(text, parsed.error) if parsed.error

      saved = MonthAssignment.set!(budget: @budget, category: @category, month: Date.current.beginning_of_month, amount: parsed.milliunits, user: Current.user)
      return render_assign_error(text, "#{saved.errors.full_messages.to_sentence}.") if saved.errors.any?

      redirect_to users_budget_path(@budget.public_id), notice: "#{@category.name} assigned #{@budget.currency_format.format_milliunits(parsed.milliunits)}."
    end

    # Cover Overspending (#57 MONEY-04): full deficit coverage only. The page
    # lists sources that can cover the whole deficit; confirming moves it in
    # one transaction. A refusal changes nothing.
    def cover
      load_cover
    end

    def cover_create
      source = CoverOverspending.eligible(@budget).find_by(public_id: params[:source_id].to_s)
      begin
        amount = CoverOverspending.cover!(budget: @budget, target: @category, source: source, month: cover_month, user: Current.user)
      rescue CoverOverspending::Refused => e
        load_cover
        @cover_error = "#{e.message} Nothing was changed."
        return render(:cover, status: :unprocessable_entity)
      end
      fmt = @budget.currency_format
      redirect_to users_budget_path(@budget.public_id),
        notice: "#{@category.name} overspending of #{fmt.format_milliunits(amount)} covered from #{source.name}."
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
      def render_assign_error(text, message)
        @show_hidden = false
        @grid, @hidden_count = PlanGrid.build(@budget)
        @assign_error = { id: @category.public_id, text: text, message: "#{message} Nothing was changed." }
        render "users/budgets/show", status: :unprocessable_entity
      end

      def cover_month
        Date.current.beginning_of_month
      end

      def load_cover
        @deficit = CoverOverspending.deficit(@budget, @category, cover_month)
        @sources = CoverOverspending.sources(@budget, @category, cover_month)
      end

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
