class CreateAccountsAndPayees < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :type, null: false
      t.string :name, null: false
      t.boolean :on_budget, null: false, default: true
      t.boolean :closed, null: false, default: false
      t.text :note
      t.bigint :balance, null: false, default: 0
      t.bigint :cleared_balance, null: false, default: 0
      t.bigint :uncleared_balance, null: false, default: 0
      t.datetime :last_reconciled_at
      t.integer :knowledge, null: false, default: 0
      t.boolean :deleted, null: false, default: false
      t.timestamps
      t.index :public_id, unique: true
      t.index [ :budget_id, :knowledge ]
    end

    create_table :payees do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :name, null: false
      t.references :transfer_account, foreign_key: { to_table: :accounts }
      t.integer :knowledge, null: false, default: 0
      t.boolean :deleted, null: false, default: false
      t.timestamps
      t.index :public_id, unique: true
      t.index [ :budget_id, :knowledge ]
    end
  end
end
