class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.string :api_token_digest

      t.timestamps
    end

    add_index :sessions, :api_token_digest, unique: true
  end
end
