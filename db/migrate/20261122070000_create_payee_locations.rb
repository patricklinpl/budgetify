class CreatePayeeLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :payee_locations do |t|
      t.references :payee, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :latitude, null: false
      t.string :longitude, null: false
      t.bigint :knowledge, null: false, default: 0
      t.boolean :deleted, null: false, default: false

      t.timestamps

      t.index :public_id, unique: true
      t.index :knowledge
    end
  end
end
