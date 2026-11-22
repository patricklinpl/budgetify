class MonthCategory < ApplicationRecord
  belongs_to :category

  validates :month, presence: true
  validates :category_id, uniqueness: { scope: :month }

  # Splits a negative month-end balance into its cash part (deducted from
  # next month's Ready to Assign) and its credit part (becomes credit-card
  # payment underfunding instead). Cash is assigned first, up to the
  # month's cash-account outflows; only the remainder is credit
  # overspending (spec: MonthSummary.to_be_budgeted; YNAB docs: cash vs
  # credit overspending).
  def self.overspend_split(balance, activity, credit_activity)
    overspend = -balance
    cash_outflows = [ -(activity.to_i - credit_activity.to_i), 0 ].max
    cash = [ overspend, cash_outflows ].min
    [ cash, overspend - cash ]
  end

  # Assigning a month amount changes the category as far as YNAB delta
  # requests are concerned, so the category's knowledge is stamped from
  # the plan's knowledge counter (spec: last_knowledge_of_server).
  after_save :stamp_category_knowledge

  private
    def stamp_category_knowledge
      category.update_column(:knowledge, category.budget.next_knowledge!)
      # Cash activity and assignments can change how much credit spending
      # was funded, including on a different card or a later month.
      if Category.column_names.include?("payment_account_id")
        category.budget.categories.not_deleted.where.not(payment_account_id: nil).find_each do |payment|
          payment.update_column(:knowledge, category.budget.next_knowledge!)
        end
      end
    end
end
