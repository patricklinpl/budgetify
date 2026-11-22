class MonthCategory < ApplicationRecord
  belongs_to :category

  validates :month, presence: true
  validates :category_id, uniqueness: { scope: :month }

  # Splits a negative month-end balance into its cash part (deducted from
  # next month's Ready to Assign) and its credit part (becomes credit-card
  # payment underfunding instead), crediting up to the month's
  # credit-account outflows (spec: MonthSummary.to_be_budgeted; YNAB docs:
  # cash vs credit overspending).
  def self.overspend_split(balance, credit_activity)
    overspend = -balance
    credit = [ overspend, [ -credit_activity.to_i, 0 ].max ].min
    [ overspend - credit, credit ]
  end

  # Assigning a month amount changes the category as far as YNAB delta
  # requests are concerned, so the category's knowledge is stamped from
  # the plan's knowledge counter (spec: last_knowledge_of_server).
  after_save :stamp_category_knowledge

  private
    def stamp_category_knowledge
      category.update_column(:knowledge, category.budget.next_knowledge!)
    end
end
