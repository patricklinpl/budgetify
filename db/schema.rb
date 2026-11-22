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

ActiveRecord::Schema[8.1].define(version: 2026_11_21_200000) do
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

  add_foreign_key "budgets", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "accounts", "budgets"
  add_foreign_key "payees", "accounts", column: "transfer_account_id"
  add_foreign_key "payees", "budgets"
end
