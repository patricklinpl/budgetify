class CreateBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :budgets do |t|
      t.references :user, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :name, null: false

      t.timestamps
    end

    add_index :budgets, :public_id, unique: true
    add_index :budgets, [ :user_id, :name ]
  end
end
