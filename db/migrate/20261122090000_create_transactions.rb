class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.references :budget, null: false, foreign_key: true
      t.string :public_id, null: false
      t.references :account, null: false, foreign_key: true
      t.date :date, null: false
      t.bigint :amount, default: 0, null: false
      t.text :memo
      t.string :cleared, default: "uncleared", null: false
      t.boolean :approved, default: false, null: false
      t.string :flag_color
      t.string :flag_name
      t.references :payee, foreign_key: true
      t.references :category, foreign_key: true
      t.references :transfer_account, foreign_key: { to_table: :accounts }
      t.bigint :transfer_transaction_id
      t.bigint :matched_transaction_id
      t.string :import_id
      t.string :import_payee_name
      t.string :import_payee_name_original
      t.string :debt_transaction_type
      t.bigint :knowledge, default: 0, null: false
      t.boolean :deleted, default: false, null: false
      t.timestamps
      t.index [ :public_id ], unique: true
      t.index [ :budget_id, :knowledge ]
      t.index [ :budget_id, :date ]
      t.index [ :account_id, :date ]
      t.index [ :category_id, :date ]
      t.index [ :payee_id, :date ]
      t.index [ :import_id ]
    end

    create_table :sub_transactions do |t|
      t.references :transaction, null: false, foreign_key: true
      t.string :public_id, null: false
      t.bigint :amount, default: 0, null: false
      t.text :memo
      t.references :payee, foreign_key: true
      t.references :category, foreign_key: true
      t.references :transfer_account, foreign_key: { to_table: :accounts }
      t.bigint :transfer_transaction_id
      t.boolean :deleted, default: false, null: false
      t.timestamps
      t.index [ :public_id ], unique: true
    end
  end
end
