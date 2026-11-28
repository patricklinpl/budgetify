# The file a user previewed, kept so the confirm step can read the same bytes.
# Short-lived: removed on confirm and purged by age (ImportDraft.purge_stale!).
class CreateImportDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :import_drafts do |t|
      t.references :budget, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :token, null: false
      t.string :filename
      t.text :data, null: false
      t.text :settings_json, null: false
      t.timestamps
    end
    add_index :import_drafts, :token, unique: true
  end
end
