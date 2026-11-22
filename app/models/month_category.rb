class MonthCategory < ApplicationRecord
  belongs_to :category

  validates :month, presence: true
  validates :category_id, uniqueness: { scope: :month }

  # Assigning a month amount changes the category as far as YNAB delta
  # requests are concerned, so the category's knowledge is stamped from
  # the plan's knowledge counter (spec: last_knowledge_of_server).
  after_save :stamp_category_knowledge

  private
    def stamp_category_knowledge
      category.update_column(:knowledge, category.budget.next_knowledge!)
    end
end
