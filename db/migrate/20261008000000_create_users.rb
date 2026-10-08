class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :public_id, null: false
      t.boolean :is_local, null: false, default: false

      t.timestamps
    end

    add_index :users, :public_id, unique: true
    add_index :users, :is_local, unique: true, where: "is_local = 1"
  end
end
