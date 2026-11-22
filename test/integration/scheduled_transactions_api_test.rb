require "test_helper"

# Request-level checks for the scheduled transaction endpoints (issue #34):
# list/create/show/update/delete with delta support (spec:
# ScheduledTransactionsResponse, ScheduledTransactionResponse).
class ScheduledTransactionsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "scheduled-transactions@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
    @groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    @future = Date.current + 7
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/plans/#{@plan.public_id}/scheduled_transactions"

    assert_response :unauthorized
    assert_equal "not_authorized", response.parsed_body.fetch("error").fetch("name")
  end

  test "unknown plans get a 404.2 in the error envelope" do
    get "/v1/plans/does-not-exist/scheduled_transactions", headers: auth_headers

    assert_response :not_found
    assert_equal "404.2", response.parsed_body.fetch("error").fetch("id")
  end

  test "POST creates a scheduled transaction with detail" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, amount: -45000, frequency: "monthly", category_id: @groceries.public_id, payee_name: "Coffee Shop", memo: "beans" } },
      headers: auth_headers, as: :json

    assert_response :created
    scheduled = response.parsed_body.dig("data", "scheduled_transaction")
    assert_equal @future.iso8601, scheduled["date_first"]
    assert_equal @future.iso8601, scheduled["date_next"]
    assert_equal "monthly", scheduled["frequency"]
    assert_equal(-45000, scheduled["amount"])
    assert_equal "Checking", scheduled["account_name"]
    assert_equal "Coffee Shop", scheduled["payee_name"]
    assert_equal "Groceries", scheduled["category_name"]
    assert_equal [], scheduled["subtransactions"]
    assert_equal false, scheduled["deleted"]
  end

  test "POST with a past date gets a 400" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: (Date.current - 1).iso8601, amount: -100 } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "POST with an invalid frequency gets a 400" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, amount: -100, frequency: "sometimes" } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "GET list returns detail items and server_knowledge" do
    @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions", headers: auth_headers

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert data.key?("server_knowledge")
    assert_equal 1, data.fetch("scheduled_transactions").size
    assert_equal "Checking", data.fetch("scheduled_transactions").first.fetch("account_name")
  end

  test "GET list delta returns only newer records" do
    @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)
    knowledge = @plan.reload.server_knowledge
    @plan.scheduled_transactions.create!(account: @account, date_first: @future + 1, date_next: @future + 1, amount: -2000)

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions?last_knowledge_of_server=#{knowledge}", headers: auth_headers

    assert_response :ok
    rows = response.parsed_body.dig("data", "scheduled_transactions")
    assert_equal 1, rows.size
    assert_equal(-2000, rows.first.fetch("amount"))
  end

  test "GET one returns the detail" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal scheduled.public_id, response.parsed_body.dig("data", "scheduled_transaction", "id")
  end

  test "GET unknown id gets a 404.2" do
    get "/v1/plans/#{@plan.public_id}/scheduled_transactions/does-not-exist", headers: auth_headers

    assert_response :not_found
    assert_equal "404.2", response.parsed_body.fetch("error").fetch("id")
  end

  test "PUT updates fields and recomputes date_next from the new date" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000, frequency: "weekly")
    new_date = Date.current + 21

    put "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}",
      params: { scheduled_transaction: { account_id: @account.public_id, date: new_date.iso8601, amount: -3000, frequency: "everyOtherWeek" } },
      headers: auth_headers, as: :json

    assert_response :ok
    body = response.parsed_body.dig("data", "scheduled_transaction")
    assert_equal new_date.iso8601, body["date_first"]
    assert_equal new_date.iso8601, body["date_next"]
    assert_equal "everyOtherWeek", body["frequency"]
    assert_equal(-3000, body["amount"])
  end

  test "PUT with a past date gets a 400" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)

    put "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}",
      params: { scheduled_transaction: { account_id: @account.public_id, date: (Date.current - 3).iso8601 } },
      headers: auth_headers, as: :json

    assert_response :bad_request
  end

  test "DELETE marks deleted and hides the record from plain lists" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)

    delete "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}", headers: auth_headers

    assert_response :ok
    assert_equal true, response.parsed_body.dig("data", "scheduled_transaction", "deleted")

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions", headers: auth_headers
    assert_empty response.parsed_body.dig("data", "scheduled_transactions")
  end

  test "DELETE tombstone appears in delta requests" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -1000)
    knowledge = @plan.reload.server_knowledge
    delete "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}", headers: auth_headers
    assert_response :ok

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions?last_knowledge_of_server=#{knowledge}", headers: auth_headers
    rows = response.parsed_body.dig("data", "scheduled_transactions")
    assert_equal 1, rows.size
    assert_equal true, rows.first.fetch("deleted")
  end

  test "transfers pair with the target account's transfer payee" do
    target = @plan.accounts.create!(name: "Savings", type: "savings")

    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, amount: -25000, transfer_account_id: target.public_id } },
      headers: auth_headers, as: :json

    assert_response :created
    scheduled = response.parsed_body.dig("data", "scheduled_transaction")
    assert_equal target.public_id, scheduled["transfer_account_id"]
    assert_equal "Transfer : Savings", scheduled["payee_name"]
  end

  test "detail shows Split category_name when subtransactions exist" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -80000)
    scheduled.scheduled_sub_transactions.create!(amount: -30000, category: @groceries)
    scheduled.scheduled_sub_transactions.create!(amount: -50000)

    get "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}", headers: auth_headers

    assert_response :ok
    body = response.parsed_body.dig("data", "scheduled_transaction")
    assert_equal "Split", body["category_name"]
    assert_equal 2, body["subtransactions"].size
    assert_equal "Groceries", body["subtransactions"].first["category_name"]
  end

  test "date_next recomputation advances past occurrences to the next future one" do
    first = Date.current - 10
    scheduled = @plan.scheduled_transactions.new(account: @account, date_first: first, amount: -100, frequency: "weekly")
    scheduled.recompute_date_next!

    assert scheduled.date_next >= Date.current
    assert_equal 0, (scheduled.date_next - first) % 7
  end

  test "past dates remain invalid even for repeating schedules" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: (Date.current - 10).iso8601, frequency: "weekly" } },
      headers: auth_headers, as: :json
    assert_response :bad_request
  end

  test "date is capped at five years and required on PUT with account" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: Date.current.advance(years: 6).iso8601 } },
      headers: auth_headers, as: :json
    assert_response :bad_request
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future)
    put "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}",
      params: { scheduled_transaction: { amount: -100 } }, headers: auth_headers, as: :json
    assert_response :bad_request
  end

  test "payment categories and split creation are rejected without balance effects" do
    card = @plan.accounts.create!(name: "Visa", type: "creditCard")
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: card.public_id, date: @future.iso8601, category_id: card.payment_category.public_id } },
      headers: auth_headers, as: :json
    assert_response :bad_request
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, subtransactions: [ { amount: -100 } ] } },
      headers: auth_headers, as: :json
    assert_response :bad_request
    assert_equal 0, @account.reload.balance
    assert_equal 0, card.reload.balance
    assert_empty @plan.transactions
  end

  test "anchored monthly and twice-monthly recurrence does not drift" do
    first = Date.new(2027, 1, 31)
    assert_equal Date.new(2027, 2, 28), ScheduledTransaction.occurrence(first, "monthly", 1)
    assert_equal Date.new(2027, 3, 31), ScheduledTransaction.occurrence(first, "monthly", 2)
    first = Date.new(2027, 1, 5)
    assert_equal Date.new(2027, 1, 20), ScheduledTransaction.occurrence(first, "twiceAMonth", 1)
    assert_equal Date.new(2027, 2, 5), ScheduledTransaction.occurrence(first, "twiceAMonth", 2)
    assert_equal Date.new(2027, 2, 20), ScheduledTransaction.occurrence(first, "twiceAMonth", 3)
  end

  test "failed writes leave no orphan payee or partial schedule edits" do
    post "/v1/plans/#{@plan.public_id}/scheduled_transactions",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, payee_name: "Must Roll Back", frequency: "invalid" } },
      headers: auth_headers, as: :json
    assert_response :bad_request
    assert_not @plan.payees.exists?(name: "Must Roll Back")
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: @future, date_next: @future, amount: -100)
    put "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, amount: -500, frequency: "invalid", payee_name: "Must Roll Back" } },
      headers: auth_headers, as: :json
    assert_response :bad_request
    assert_equal(-100, scheduled.reload.amount)
    assert_equal "never", scheduled.frequency
    assert_not @plan.payees.exists?(name: "Must Roll Back")
  end

  test "scheduled schema preserves the credit-card payment category index" do
    assert ActiveRecord::Base.connection.index_exists?(:categories, :payment_account_id)
  end

  test "an expired never schedule can be rescheduled with a new future date" do
    scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: Date.current - 2, date_next: Date.current - 2, frequency: "never")
    put "/v1/plans/#{@plan.public_id}/scheduled_transactions/#{scheduled.public_id}",
      params: { scheduled_transaction: { account_id: @account.public_id, date: @future.iso8601, amount: -900 } }, headers: auth_headers, as: :json
    assert_response :ok
    assert_equal @future, scheduled.reload.date_next
    assert_equal(-900, scheduled.amount)
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
