class CreateMoneyMovements < ActiveRecord::Migration[8.1]
  def change
    create_table :money_movement_groups do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.datetime :group_created_at, null: false
      t.date :month, null: false
      t.text :note
      t.references :performed_by_user, foreign_key: { to_table: :users }
      t.bigint :knowledge, default: 0, null: false
      t.boolean :deleted, default: false, null: false
      t.timestamps
      t.index [ :public_id ], unique: true
      t.index [ :budget_id, :knowledge ]
      t.index [ :budget_id, :month ]
    end

    create_table :money_movements do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.references :money_movement_group, foreign_key: true
      t.date :month, null: false
      t.datetime :moved_at
      t.text :note
      t.references :performed_by_user, foreign_key: { to_table: :users }
      t.references :from_category, foreign_key: { to_table: :categories }
      t.references :to_category, foreign_key: { to_table: :categories }
      t.bigint :amount, null: false
      t.bigint :knowledge, default: 0, null: false
      t.boolean :deleted, default: false, null: false
      t.timestamps
      t.index [ :public_id ], unique: true
      t.index [ :budget_id, :knowledge ]
      t.index [ :budget_id, :month ]
    end
  end
end
