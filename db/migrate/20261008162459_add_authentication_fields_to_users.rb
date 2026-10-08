class AddAuthenticationFieldsToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :email_address, :string
    add_column :users, :password_digest, :string
    add_index :users, :email_address, unique: true
    remove_index :users, :is_local
    remove_column :users, :is_local, :boolean, null: false, default: false
  end

  def down
    add_column :users, :is_local, :boolean, null: false, default: false
    add_index :users, :is_local, unique: true, where: "is_local = 1"
    remove_index :users, :email_address
    remove_column :users, :password_digest
    remove_column :users, :email_address
  end
end
