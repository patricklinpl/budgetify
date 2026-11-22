class CreateCategoryGroupsAndCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :category_groups do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :name, null: false
      t.boolean :hidden, null: false, default: false
      t.boolean :internal, null: false, default: false
      t.boolean :deleted, null: false, default: false
      t.bigint :knowledge, null: false, default: 0
      t.timestamps
    end
    add_index :category_groups, :public_id, unique: true
    add_index :category_groups, [ :budget_id, :knowledge ]

    create_table :categories do |t|
      t.references :budget, null: false, foreign_key: true
      t.references :category_group, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :name, null: false
      t.boolean :hidden, null: false, default: false
      t.boolean :internal, null: false, default: false
      t.text :note
      t.string :goal_type
      t.bigint :goal_target
      t.date :goal_target_date
      t.integer :goal_cadence
      t.integer :goal_cadence_frequency
      t.integer :goal_day
      t.date :goal_creation_month
      t.boolean :goal_needs_whole_amount
      t.boolean :deleted, null: false, default: false
      t.bigint :knowledge, null: false, default: 0
      t.timestamps
    end
    add_index :categories, :public_id, unique: true
    add_index :categories, [ :budget_id, :knowledge ]

    # Per-month assigned/activity/available amounts (spec: amounts are
    # specific to the plan month).
    create_table :month_categories do |t|
      t.references :category, null: false, foreign_key: true
      t.date :month, null: false
      t.bigint :budgeted, null: false, default: 0
      t.bigint :activity, null: false, default: 0
      t.bigint :balance, null: false, default: 0
      t.timestamps
    end
    add_index :month_categories, [ :category_id, :month ], unique: true
  end
end
