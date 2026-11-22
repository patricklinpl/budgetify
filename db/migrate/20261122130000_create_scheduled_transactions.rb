class CreateScheduledTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_transactions do |t|
      t.references :budget, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :payee, foreign_key: true
      t.references :category, foreign_key: true
      t.references :transfer_account, foreign_key: { to_table: :accounts }
      t.string :public_id, null: false
      t.date :date_first, null: false
      t.date :date_next, null: false
      t.string :frequency, null: false, default: "never"
      t.integer :amount, null: false, default: 0
      t.string :memo
      t.string :flag_color
      t.string :flag_name
      t.boolean :deleted, null: false, default: false
      t.integer :knowledge, null: false, default: 0

      t.timestamps
    end
    add_index :scheduled_transactions, :public_id, unique: true
    add_index :scheduled_transactions, [ :budget_id, :knowledge ]

    create_table :scheduled_sub_transactions do |t|
      t.references :scheduled_transaction, null: false, foreign_key: true
      t.references :payee, foreign_key: true
      t.references :category, foreign_key: true
      t.references :transfer_account, foreign_key: { to_table: :accounts }
      t.string :public_id, null: false
      t.integer :amount, null: false, default: 0
      t.string :memo
      t.boolean :deleted, null: false, default: false

      t.timestamps
    end
    add_index :scheduled_sub_transactions, :public_id, unique: true
  end
end
