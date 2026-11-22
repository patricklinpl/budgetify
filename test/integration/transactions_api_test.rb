require "test_helper"

# Request-level checks for the transaction endpoints (issue #33):
# list/create/bulk-update/show/update/delete, account/category/payee/month
# scoped lists, and the import stub.
class TransactionsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "transactions@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
    @groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    @current = Date.current.beginning_of_month
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/transactions"

    assert_response :unauthorized
    assert_equal "not_authorized", response.parsed_body.fetch("error").fetch("name")
  end

  test "unknown plans get a 404.2 in the error envelope" do
    get "/v1/plans/does-not-exist/transactions", headers: auth_headers

    assert_response :not_found
    assert_equal "404.2", response.parsed_body.fetch("error").fetch("id")
  end

  test "POST creates a transaction with detail and id list" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -45000, category_id: @groceries.public_id, payee_name: "Coffee Shop", memo: "beans", cleared: "cleared", approved: true } },
      headers: auth_headers, as: :json

    assert_response :created
    data = response.parsed_body.fetch("data")
    transaction = data.fetch("transaction")
    assert_equal [ transaction.fetch("id") ], data.fetch("transaction_ids")
    assert_equal(-45000, transaction.fetch("amount"))
    assert_equal(-45.0, transaction.fetch("amount_currency"))
    assert_equal "-$45.00", transaction.fetch("amount_formatted")
    assert_equal "Coffee Shop", transaction.fetch("payee_name")
    assert_equal "Groceries", transaction.fetch("category_name")
    assert_equal "Checking", transaction.fetch("account_name")
    assert_equal false, transaction.fetch("deleted")
    assert data.key?("server_knowledge")
  end

  test "transactions update account and category activity" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -45000, category_id: @groceries.public_id, cleared: "cleared" } },
      headers: auth_headers, as: :json

    get "/v1/plans/#{@plan.public_id}/accounts/#{@account.public_id}", headers: auth_headers
    account = response.parsed_body.fetch("data").fetch("account")
    assert_equal(-45000, account.fetch("balance"))
    assert_equal(-45000, account.fetch("cleared_balance"))
    assert_equal 0, account.fetch("uncleared_balance")

    get "/v1/plans/#{@plan.public_id}/months", headers: auth_headers
    month = response.parsed_body.fetch("data").fetch("months").find { |m| m.fetch("month") == @current.iso8601 }
    assert_equal(-45000, month.fetch("activity"))
    assert_equal 0, month.fetch("income")
    assert_equal(-45000, month.fetch("to_be_budgeted")) # cash overspend absorbed
  end

  test "POST with payee_name resolves or creates the payee" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -1000, payee_name: "Corner Store" } },
      headers: auth_headers, as: :json

    assert_response :created
    assert @plan.payees.not_deleted.exists?(name: "Corner Store")
  end

  test "POST rejects future dates with a 400" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: 1.month.from_now.to_date.iso8601, amount: -1000 } },
      headers: auth_headers, as: :json

    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.fetch("error").fetch("name")
  end

  test "split transactions validate sub amounts sum to the parent" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -10000, subtransactions: [ { amount: -4000, category_id: @groceries.public_id }, { amount: -5000 } ] } },
      headers: auth_headers, as: :json

    assert_response :bad_request

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -10000, subtransactions: [ { amount: -4000, category_id: @groceries.public_id }, { amount: -6000 } ] } },
      headers: auth_headers, as: :json

    assert_response :created
    transaction = response.parsed_body.fetch("data").fetch("transaction")
    assert_equal "Split", transaction.fetch("category_name")
    assert_equal 2, transaction.fetch("subtransactions").size
  end

  test "transfers auto-create the paired transaction" do
    savings = @plan.accounts.create!(name: "Savings", type: "savings")
    transfer_payee = @plan.payees.create!(name: "Transfer : Savings", transfer_account: savings)

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -200000, payee_id: transfer_payee.public_id } },
      headers: auth_headers, as: :json

    assert_response :created
    transaction = response.parsed_body.fetch("data").fetch("transaction")
    assert_equal savings.public_id, transaction.fetch("transfer_account_id")
    pair_id = transaction.fetch("transfer_transaction_id")
    assert_not_nil pair_id

    get "/v1/plans/#{@plan.public_id}/transactions/#{pair_id}", headers: auth_headers
    pair = response.parsed_body.fetch("data").fetch("transaction")
    assert_equal 200000, pair.fetch("amount")
    assert_equal @account.public_id, pair.fetch("transfer_account_id")
  end

  test "bulk create reports duplicate import ids without duplicating" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transactions: [
        { account_id: @account.public_id, date: @current.iso8601, amount: -1000, import_id: "bank:1" },
        { account_id: @account.public_id, date: @current.iso8601, amount: -2000, import_id: "bank:1" }
      ] },
      headers: auth_headers, as: :json

    assert_response :created
    assert_equal 2, response.parsed_body.fetch("data").fetch("transaction_ids").size

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transactions: [ { account_id: @account.public_id, date: @current.iso8601, amount: -3000, import_id: "bank:1" } ] },
      headers: auth_headers, as: :json

    assert_response :created
    data = response.parsed_body.fetch("data")
    assert_equal [], data.fetch("transaction_ids")
    assert_equal [ "bank:1" ], data.fetch("duplicate_import_ids")
  end

  test "PUT updates a transaction and reverses old amounts" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -45000, category_id: @groceries.public_id } },
      headers: auth_headers, as: :json
    id = response.parsed_body.fetch("data").fetch("transaction").fetch("id")

    put "/v1/plans/#{@plan.public_id}/transactions/#{id}",
      params: { transaction: { amount: -50000, memo: "updated" } },
      headers: auth_headers, as: :json

    assert_response :ok
    transaction = response.parsed_body.fetch("data").fetch("transaction")
    assert_equal(-50000, transaction.fetch("amount"))
    assert_equal "updated", transaction.fetch("memo")

    get "/v1/plans/#{@plan.public_id}/accounts/#{@account.public_id}", headers: auth_headers
    assert_equal(-50000, response.parsed_body.fetch("data").fetch("account").fetch("balance"))
  end

  test "PATCH bulk updates by id and import_id" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transactions: [
        { account_id: @account.public_id, date: @current.iso8601, amount: -1000, import_id: "bank:1" },
        { account_id: @account.public_id, date: @current.iso8601, amount: -2000 }
      ] },
      headers: auth_headers, as: :json
    ids = response.parsed_body.fetch("data").fetch("transaction_ids")

    patch "/v1/plans/#{@plan.public_id}/transactions",
      params: { transactions: [
        { import_id: "bank:1", approved: true },
        { id: ids.last, approved: true }
      ] },
      headers: auth_headers, as: :json

    assert_response :ok
    transactions = response.parsed_body.fetch("data").fetch("transactions")
    assert_equal 2, transactions.size
    assert transactions.all? { |t| t.fetch("approved") == true }
  end

  test "DELETE soft deletes the transaction and its pair" do
    savings = @plan.accounts.create!(name: "Savings", type: "savings")
    transfer_payee = @plan.payees.create!(name: "Transfer : Savings", transfer_account: savings)
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: @current.iso8601, amount: -200000, payee_id: transfer_payee.public_id } },
      headers: auth_headers, as: :json
    transaction = response.parsed_body.fetch("data").fetch("transaction")

    delete "/v1/plans/#{@plan.public_id}/transactions/#{transaction.fetch("id")}", headers: auth_headers

    assert_response :ok
    assert_equal true, response.parsed_body.fetch("data").fetch("transaction").fetch("deleted")

    get "/v1/plans/#{@plan.public_id}/accounts/#{@account.public_id}", headers: auth_headers
    assert_equal 0, response.parsed_body.fetch("data").fetch("account").fetch("balance")
  end

  test "GET transactions filters by since_date, until_date and type" do
    create_transaction(amount: -1000, date: @current, approved: false)
    create_transaction(amount: -2000, date: @current, approved: true, category: @groceries)

    get "/v1/plans/#{@plan.public_id}/transactions", headers: auth_headers, params: { type: "unapproved" }
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size

    get "/v1/plans/#{@plan.public_id}/transactions", headers: auth_headers, params: { type: "uncategorized" }
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size

    get "/v1/plans/#{@plan.public_id}/transactions", headers: auth_headers, params: { since_date: (@current + 1.day).iso8601 }
    assert_equal 0, response.parsed_body.fetch("data").fetch("transactions").size
  end

  test "scoped lists return hybrid transactions with server_knowledge" do
    create_transaction(amount: -1000, date: @current, category: @groceries, payee_name: "Corner Store")
    payee = @plan.payees.not_deleted.find_by(name: "Corner Store")

    get "/v1/plans/#{@plan.public_id}/accounts/#{@account.public_id}/transactions", headers: auth_headers
    assert_response :ok
    rows = response.parsed_body.fetch("data").fetch("transactions")
    assert_equal "transaction", rows.first.fetch("type")
    assert response.parsed_body.fetch("data").key?("server_knowledge")

    get "/v1/plans/#{@plan.public_id}/categories/#{@groceries.public_id}/transactions", headers: auth_headers
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size

    get "/v1/plans/#{@plan.public_id}/payees/#{payee.public_id}/transactions", headers: auth_headers
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size

    get "/v1/plans/#{@plan.public_id}/months/#{@current.iso8601}/transactions", headers: auth_headers
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size
  end

  test "unknown scoped ids get a 404.2" do
    get "/v1/plans/#{@plan.public_id}/accounts/00000000-0000-0000-0000-000000000000/transactions", headers: auth_headers
    assert_response :not_found

    get "/v1/plans/#{@plan.public_id}/transactions/00000000-0000-0000-0000-000000000000", headers: auth_headers
    assert_response :not_found
  end

  test "POST transactions/import returns empty ids" do
    post "/v1/plans/#{@plan.public_id}/transactions/import", headers: auth_headers, as: :json

    assert_response :created
    data = response.parsed_body.fetch("data")
    assert_equal [], data.fetch("transaction_ids")
    assert data.key?("server_knowledge")
  end

  test "GET transactions supports last_knowledge_of_server delta" do
    get "/v1/plans/#{@plan.public_id}/transactions", headers: auth_headers
    knowledge = response.parsed_body.fetch("data").fetch("server_knowledge")

    create_transaction(amount: -1000, date: @current)

    get "/v1/plans/#{@plan.public_id}/transactions", headers: auth_headers, params: { last_knowledge_of_server: knowledge }
    assert_equal 1, response.parsed_body.fetch("data").fetch("transactions").size
  end

  private
    def create_transaction(amount:, date:, approved: true, category: nil, payee_name: nil)
      post "/v1/plans/#{@plan.public_id}/transactions",
        params: { transaction: { account_id: @account.public_id, date: date.iso8601, amount: amount, approved: approved, category_id: category&.public_id, payee_name: payee_name } },
        headers: auth_headers, as: :json
      assert_response :created
    end

    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end

  test "POST with an existing import_id returns duplicate_import_ids and creates nothing" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: Date.current.iso8601, amount: -1200, import_id: "bank:dup-1" } },
      headers: auth_headers, as: :json
    assert_response :created

    assert_no_difference -> { @plan.transactions.count } do
      post "/v1/plans/#{@plan.public_id}/transactions",
        params: { transaction: { account_id: @account.public_id, date: Date.current.iso8601, amount: -1200, import_id: "bank:dup-1" } },
        headers: auth_headers, as: :json
      assert_response :created
    end
    data = response.parsed_body["data"]
    assert_equal [], data["transaction_ids"]
    assert_equal [ "bank:dup-1" ], data["duplicate_import_ids"]
  end

  test "POST with transfer_account_id pairs a mirror transaction in the target account" do
    target = @plan.accounts.create!(name: "Savings", type: "savings")
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: Date.current.iso8601, amount: -25000, transfer_account_id: target.public_id } },
      headers: auth_headers, as: :json
    assert_response :created
    transaction = response.parsed_body.dig("data", "transaction")
    assert_equal target.public_id, transaction["transfer_account_id"]
    assert transaction["transfer_transaction_id"].present?

    get "/v1/plans/#{@plan.public_id}/accounts/#{target.public_id}/transactions", headers: auth_headers
    assert_response :ok
    mirror = response.parsed_body.dig("data", "transactions").first
    assert_equal 25000, mirror["amount"]
    assert_equal @account.public_id, mirror["transfer_account_id"]
  end

  test "GET category transactions includes split subtransactions for that category" do
    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: @account.public_id, date: Date.current.iso8601, amount: -80000,
        subtransactions: [ { amount: -30000, category_id: @groceries.public_id }, { amount: -50000 } ] } },
      headers: auth_headers, as: :json
    assert_response :created

    get "/v1/plans/#{@plan.public_id}/categories/#{@groceries.public_id}/transactions", headers: auth_headers
    assert_response :ok
    types = response.parsed_body.dig("data", "transactions").map { |row| row["type"] }
    assert_includes types, "subtransaction"
  end
end
