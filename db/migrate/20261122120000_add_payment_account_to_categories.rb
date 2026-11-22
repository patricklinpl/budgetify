# YNAB auto-creates one Credit Card Payment category per credit account
# (grouped under "Credit Card Payments"); funded credit spending moves
# funds into it (YNAB docs: Handling Credit Cards / Credit Card
# Overspending / Credit Card Payments guides; spec: SaveCategory.goal_type
# 'MF' default acknowledges these system categories). Existing credit
# accounts are backfilled here; new ones get theirs from Account callbacks.
class AddPaymentAccountToCategories < ActiveRecord::Migration[8.1]
  def up
    add_column :categories, :payment_account_id, :integer
    add_index :categories, :payment_account_id

    Account.reset_column_information
    Category.reset_column_information
    Account.where(type: Account::CREDIT_TYPES, deleted: false).find_each do |account|
      account.ensure_payment_category!
    end
  end

  def down
    remove_index :categories, :payment_account_id
    remove_column :categories, :payment_account_id
  end
end
