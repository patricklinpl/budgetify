class AddApiFoundationsToBudgetsAndUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :budgets do |t|
      # YNAB "last-used" plan resolution.
      t.datetime :last_used_at
      # Per-plan knowledge counter for delta requests under /v1/plans/{plan_id}/...
      t.integer :server_knowledge, null: false, default: 0
      # This plan's own knowledge in the user's global counter (plans-list deltas).
      t.integer :knowledge, null: false, default: 0
      # YNAB tombstones: API-visible deletes are soft, never hard.
      t.boolean :deleted, null: false, default: false
    end

    # User-global knowledge counter for delta requests on the plans list.
    add_column :users, :server_knowledge, :integer, null: false, default: 0
  end
end
