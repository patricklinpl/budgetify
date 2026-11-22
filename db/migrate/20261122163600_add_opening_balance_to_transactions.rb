class AddOpeningBalanceToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :opening_balance, :boolean, null: false, default: false
  end
end
