# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_22_090000) do
  create_table "accounts", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.string "type", null: false
    t.string "name", null: false
    t.boolean "on_budget", default: true, null: false
    t.boolean "closed", default: false, null: false
    t.text "note"
    t.bigint "balance", default: 0, null: false
    t.bigint "cleared_balance", default: 0, null: false
    t.bigint "uncleared_balance", default: 0, null: false
    t.datetime "last_reconciled_at"
    t.integer "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_accounts_on_budget_id_and_knowledge"
    t.index ["budget_id"], name: "index_accounts_on_budget_id"
    t.index ["public_id"], name: "index_accounts_on_public_id", unique: true
  end

  create_table "budgets", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "public_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_used_at"
    t.integer "server_knowledge", default: 0, null: false
    t.integer "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.string "date_format", default: "MM/DD/YYYY", null: false
    t.json "currency_format"
    t.index ["public_id"], name: "index_budgets_on_public_id", unique: true
    t.index ["user_id", "name"], name: "index_budgets_on_user_id_and_name"
    t.index ["user_id"], name: "index_budgets_on_user_id"
  end

  create_table "categories", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.integer "category_group_id", null: false
    t.string "public_id", null: false
    t.string "name", null: false
    t.boolean "hidden", default: false, null: false
    t.boolean "internal", default: false, null: false
    t.text "note"
    t.string "goal_type"
    t.bigint "goal_target"
    t.date "goal_target_date"
    t.integer "goal_cadence"
    t.integer "goal_cadence_frequency"
    t.integer "goal_day"
    t.date "goal_creation_month"
    t.boolean "goal_needs_whole_amount"
    t.boolean "deleted", default: false, null: false
    t.bigint "knowledge", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_categories_on_budget_id_and_knowledge"
    t.index ["budget_id"], name: "index_categories_on_budget_id"
    t.index ["category_group_id"], name: "index_categories_on_category_group_id"
    t.index ["public_id"], name: "index_categories_on_public_id", unique: true
  end

  create_table "category_groups", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.string "name", null: false
    t.boolean "hidden", default: false, null: false
    t.boolean "internal", default: false, null: false
    t.boolean "deleted", default: false, null: false
    t.bigint "knowledge", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_category_groups_on_budget_id_and_knowledge"
    t.index ["budget_id"], name: "index_category_groups_on_budget_id"
    t.index ["public_id"], name: "index_category_groups_on_public_id", unique: true
  end

  create_table "money_movement_groups", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.datetime "group_created_at", null: false
    t.date "month", null: false
    t.text "note"
    t.integer "performed_by_user_id"
    t.bigint "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_money_movement_groups_on_budget_id_and_knowledge"
    t.index ["budget_id", "month"], name: "index_money_movement_groups_on_budget_id_and_month"
    t.index ["budget_id"], name: "index_money_movement_groups_on_budget_id"
    t.index ["performed_by_user_id"], name: "index_money_movement_groups_on_performed_by_user_id"
    t.index ["public_id"], name: "index_money_movement_groups_on_public_id", unique: true
  end

  create_table "money_movements", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.integer "money_movement_group_id"
    t.date "month", null: false
    t.datetime "moved_at"
    t.text "note"
    t.integer "performed_by_user_id"
    t.integer "from_category_id"
    t.integer "to_category_id"
    t.bigint "amount", null: false
    t.bigint "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_money_movements_on_budget_id_and_knowledge"
    t.index ["budget_id", "month"], name: "index_money_movements_on_budget_id_and_month"
    t.index ["budget_id"], name: "index_money_movements_on_budget_id"
    t.index ["from_category_id"], name: "index_money_movements_on_from_category_id"
    t.index ["money_movement_group_id"], name: "index_money_movements_on_money_movement_group_id"
    t.index ["performed_by_user_id"], name: "index_money_movements_on_performed_by_user_id"
    t.index ["public_id"], name: "index_money_movements_on_public_id", unique: true
    t.index ["to_category_id"], name: "index_money_movements_on_to_category_id"
  end

  create_table "month_categories", force: :cascade do |t|
    t.integer "category_id", null: false
    t.date "month", null: false
    t.bigint "budgeted", default: 0, null: false
    t.bigint "activity", default: 0, null: false
    t.bigint "balance", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id", "month"], name: "index_month_categories_on_category_id_and_month", unique: true
    t.index ["category_id"], name: "index_month_categories_on_category_id"
  end

  create_table "payee_locations", force: :cascade do |t|
    t.integer "payee_id", null: false
    t.string "public_id", null: false
    t.string "latitude", null: false
    t.string "longitude", null: false
    t.bigint "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["knowledge"], name: "index_payee_locations_on_knowledge"
    t.index ["payee_id"], name: "index_payee_locations_on_payee_id"
    t.index ["public_id"], name: "index_payee_locations_on_public_id", unique: true
  end

  create_table "payees", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.string "name", null: false
    t.integer "transfer_account_id"
    t.integer "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "knowledge"], name: "index_payees_on_budget_id_and_knowledge"
    t.index ["budget_id"], name: "index_payees_on_budget_id"
    t.index ["public_id"], name: "index_payees_on_public_id", unique: true
    t.index ["transfer_account_id"], name: "index_payees_on_transfer_account_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.string "api_token_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token_digest"], name: "index_sessions_on_api_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "sub_transactions", force: :cascade do |t|
    t.integer "transaction_id", null: false
    t.string "public_id", null: false
    t.bigint "amount", default: 0, null: false
    t.text "memo"
    t.integer "payee_id"
    t.integer "category_id"
    t.integer "transfer_account_id"
    t.bigint "transfer_transaction_id"
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_sub_transactions_on_category_id"
    t.index ["payee_id"], name: "index_sub_transactions_on_payee_id"
    t.index ["public_id"], name: "index_sub_transactions_on_public_id", unique: true
    t.index ["transaction_id"], name: "index_sub_transactions_on_transaction_id"
    t.index ["transfer_account_id"], name: "index_sub_transactions_on_transfer_account_id"
  end

  create_table "transactions", force: :cascade do |t|
    t.integer "budget_id", null: false
    t.string "public_id", null: false
    t.integer "account_id", null: false
    t.date "date", null: false
    t.bigint "amount", default: 0, null: false
    t.text "memo"
    t.string "cleared", default: "uncleared", null: false
    t.boolean "approved", default: false, null: false
    t.string "flag_color"
    t.string "flag_name"
    t.integer "payee_id"
    t.integer "category_id"
    t.integer "transfer_account_id"
    t.bigint "transfer_transaction_id"
    t.bigint "matched_transaction_id"
    t.string "import_id"
    t.string "import_payee_name"
    t.string "import_payee_name_original"
    t.string "debt_transaction_type"
    t.bigint "knowledge", default: 0, null: false
    t.boolean "deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "date"], name: "index_transactions_on_account_id_and_date"
    t.index ["account_id"], name: "index_transactions_on_account_id"
    t.index ["budget_id", "date"], name: "index_transactions_on_budget_id_and_date"
    t.index ["budget_id", "knowledge"], name: "index_transactions_on_budget_id_and_knowledge"
    t.index ["budget_id"], name: "index_transactions_on_budget_id"
    t.index ["category_id", "date"], name: "index_transactions_on_category_id_and_date"
    t.index ["category_id"], name: "index_transactions_on_category_id"
    t.index ["import_id"], name: "index_transactions_on_import_id"
    t.index ["payee_id", "date"], name: "index_transactions_on_payee_id_and_date"
    t.index ["payee_id"], name: "index_transactions_on_payee_id"
    t.index ["public_id"], name: "index_transactions_on_public_id", unique: true
    t.index ["transfer_account_id"], name: "index_transactions_on_transfer_account_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "public_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "email_address"
    t.string "password_digest"
    t.integer "sign_in_count", default: 0, null: false
    t.integer "server_knowledge", default: 0, null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["public_id"], name: "index_users_on_public_id", unique: true
  end

  add_foreign_key "accounts", "budgets"
  add_foreign_key "budgets", "users"
  add_foreign_key "categories", "budgets"
  add_foreign_key "categories", "category_groups"
  add_foreign_key "category_groups", "budgets"
  add_foreign_key "money_movement_groups", "budgets"
  add_foreign_key "money_movement_groups", "users", column: "performed_by_user_id"
  add_foreign_key "money_movements", "budgets"
  add_foreign_key "money_movements", "categories", column: "from_category_id"
  add_foreign_key "money_movements", "categories", column: "to_category_id"
  add_foreign_key "money_movements", "money_movement_groups"
  add_foreign_key "money_movements", "users", column: "performed_by_user_id"
  add_foreign_key "month_categories", "categories"
  add_foreign_key "payee_locations", "payees"
  add_foreign_key "payees", "accounts", column: "transfer_account_id"
  add_foreign_key "payees", "budgets"
  add_foreign_key "sessions", "users"
  add_foreign_key "sub_transactions", "accounts", column: "transfer_account_id"
  add_foreign_key "sub_transactions", "categories"
  add_foreign_key "sub_transactions", "payees"
  add_foreign_key "sub_transactions", "transactions"
  add_foreign_key "transactions", "accounts"
  add_foreign_key "transactions", "accounts", column: "transfer_account_id"
  add_foreign_key "transactions", "budgets"
  add_foreign_key "transactions", "categories"
  add_foreign_key "transactions", "payees"
end
