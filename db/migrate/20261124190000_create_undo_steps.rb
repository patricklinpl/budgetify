# Server-side Undo and Redo history (Undo slice 1). One row per recorded step,
# scoped to a user, plan, sign-in session and page-load token. The row stores
# the before and after snapshots of the rows the step touched.
class CreateUndoSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :undo_steps do |t|
      t.references :budget, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :session_key, null: false
      t.string :token, null: false
      t.integer :position, null: false
      t.string :kind, null: false
      t.boolean :undone, null: false, default: false
      t.text :before_json, null: false
      t.text :after_json, null: false
      t.integer :byte_size, null: false
      t.timestamps
    end
    add_index :undo_steps, %i[user_id budget_id session_key token position], name: "index_undo_steps_on_scope_and_position"
  end
end
