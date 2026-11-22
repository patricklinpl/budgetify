class AddPlanSettingsToBudgets < ActiveRecord::Migration[8.1]
  def change
    add_column :budgets, :date_format, :string, null: false, default: "MM/DD/YYYY"
    add_column :budgets, :currency_format, :json
  end
end
