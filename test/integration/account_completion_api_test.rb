require "test_helper"

class AccountCompletionApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "account-completion@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Complete accounts")
    @headers = { "Authorization" => "Bearer #{@token}" }
    @path = "/v1/plans/#{@plan.public_id}"
  end

  teardown { Rails.cache.clear }

  test "cash opening balance is a cleared ledger entry funding Ready to Assign exactly once" do
    post_account("checking", 125_000)
    assert_response :created
    row = response.parsed_body.dig("data", "account")
    account = @plan.accounts.find_by!(public_id: row.fetch("id"))
    assert_equal [ 125_000, 125_000, 0 ], [ row.fetch("balance"), row.fetch("cleared_balance"), row.fetch("uncleared_balance") ]
    opening = account.transactions.not_deleted.sole
    assert opening.opening_balance?
    assert_equal 125_000, opening.amount
    assert_equal "cleared", opening.cleared
    assert_equal Date.current, opening.date
    assert_equal "Starting Balance", opening.payee.name
    assert opening.category.internal?
    assert_equal 125_000, month.fetch("to_be_budgeted")
    assert_equal 125_000, month.fetch("income")
    get "#{@path}/transactions/#{opening.public_id}", headers: @headers
    assert_response :ok
    put "#{@path}/transactions/#{opening.public_id}", params: { transaction: { amount: 150_000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 150_000, account.reload.balance
    assert_equal 150_000, month.fetch("to_be_budgeted")
    delete "#{@path}/transactions/#{opening.public_id}", headers: @headers
    assert_response :ok
    assert_equal [ 0, 0, 0 ], [ account.reload.balance, account.cleared_balance, account.uncleared_balance ]
    assert_equal 0, month.fetch("to_be_budgeted")
  end

  test "negative credit starting debt does not reduce Ready to Assign or fund a payment category" do
    post_account("creditCard", -200_000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    assert_equal(-200_000, account.transactions.not_deleted.sole.amount)
    assert_nil account.transactions.not_deleted.sole.category
    assert_equal 0, month.fetch("to_be_budgeted")
    get "#{@path}/categories/#{account.payment_category.public_id}", headers: @headers
    assert_equal 0, response.parsed_body.dig("data", "category", "balance")
  end

  test "editing credit starting balance across zero updates assignable cash in both directions" do
    post_account("creditCard", -20_000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    opening = account.transactions.sole
    put "#{@path}/transactions/#{opening.public_id}", params: { transaction: { amount: 50_000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 50_000, account.reload.balance
    assert_equal 50_000, month.fetch("to_be_budgeted")
    opening.payee.update!(name: "Renamed Opening")
    put "#{@path}/transactions/#{opening.public_id}", params: { transaction: { amount: -30_000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal(-30_000, account.reload.balance)
    assert_equal 0, month.fetch("to_be_budgeted")
    delete "#{@path}/transactions/#{opening.public_id}", headers: @headers
    assert_response :ok
    assert_equal 0, account.reload.balance
    assert_equal 0, month.fetch("to_be_budgeted")
  end

  test "bulk PATCH preserves the private marker and reselects opening category by id and import_id" do
    post_account("creditCard", -20_000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    opening = account.transactions.sole
    patch "#{@path}/transactions", params: { transactions: [ { id: opening.public_id, amount: 50_000, import_id: "opening-proof", opening_balance: false } ] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 50_000, month.fetch("to_be_budgeted")
    assert opening.reload.opening_balance?, "API input must not clear the private marker"
    assert opening.category.internal?
    patch "#{@path}/transactions", params: { transactions: [ { import_id: "opening-proof", amount: -30_000 } ] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 0, month.fetch("to_be_budgeted")
    assert_nil opening.reload.category
    assert opening.opening_balance?
    assert_equal(-30_000, account.reload.balance)
  end

  test "Starting Balance payee reuse honors existing case insensitive uniqueness" do
    payee = @plan.payees.create!(name: "Starting balance")
    post_account("checking", 1000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    assert_equal payee.id, account.transactions.sole.payee_id
  end

  test "positive credit starting balance funds Ready to Assign and zero balance is represented once" do
    post_account("creditCard", 50_000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    assert_equal 50_000, account.transactions.not_deleted.sole.amount
    assert_equal 50_000, month.fetch("to_be_budgeted")
    post_account("cash", 0)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    assert_equal 1, account.transactions.count
    assert_equal 0, account.transactions.sole.amount
    assert_equal 50_000, month.fetch("to_be_budgeted")
  end

  test "tracking account openings stay outside the plan" do
    [ [ "otherAsset", 500_000 ], [ "otherLiability", -80_000 ] ].each do |type, amount|
      post_account(type, amount)
      assert_response :created
      row = response.parsed_body.dig("data", "account")
      assert_equal false, row.fetch("on_budget")
      account = @plan.accounts.find_by!(public_id: row.fetch("id"))
      assert_nil account.transactions.sole.category
      assert_equal amount, account.balance
      assert_equal 0, month.fetch("to_be_budgeted")
    end
  end

  test "cash openings follow negative and positive edits while tracking openings never enter RTA" do
    post_account("cash", -1000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    opening = account.transactions.sole
    assert_equal(-1000, month.fetch("to_be_budgeted"))
    put "#{@path}/transactions/#{opening.public_id}", params: { transaction: { amount: 2000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 2000, month.fetch("to_be_budgeted")
    post_account("otherLiability", -80_000)
    assert_response :created
    tracking = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    put "#{@path}/transactions/#{tracking.transactions.sole.public_id}", params: { transaction: { amount: 70_000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 70_000, tracking.reload.balance
    assert_equal 2000, month.fetch("to_be_budgeted")
    assert_nil tracking.transactions.sole.category
  end

  test "soft deleted Starting Balance payee is not reused and only one active replacement exists" do
    old = @plan.payees.create!(name: "Starting balance", deleted: true)
    post_account("checking", 1000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: response.parsed_body.dig("data", "account", "id"))
    opening = account.transactions.sole
    assert opening.opening_balance?
    assert_not_equal old.id, opening.payee_id
    assert_equal 1, @plan.payees.not_deleted.where("LOWER(name) = ?", "starting balance").count
    post_account("savings", 2000)
    assert_response :created
    assert_equal 1, @plan.payees.not_deleted.where("LOWER(name) = ?", "starting balance").count
  end

  test "unmarked ordinary transactions keep user categories even with a Starting Balance payee" do
    account = @plan.accounts.create!(name: "Ordinary", type: "creditCard")
    group = @plan.category_groups.create!(name: "Everyday")
    category = group.categories.create!(budget: @plan, name: "Food")
    payee = @plan.payees.create!(name: "Starting Balance")
    post "#{@path}/transactions", params: { transaction: { account_id: account.public_id, date: Date.current.iso8601,
      amount: -1000, category_id: category.public_id, payee_id: payee.public_id } }, headers: @headers, as: :json
    assert_response :created
    row = response.parsed_body.dig("data", "transaction")
    assert_not row.key?("opening_balance")
    entry = @plan.transactions.find_by!(public_id: row.fetch("id"))
    assert_not entry.opening_balance?
    put "#{@path}/transactions/#{entry.public_id}", params: { transaction: { amount: 2000 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal category.id, entry.reload.category_id
    assert_not entry.opening_balance?
  end

  test "account balances use plan currency on create list and get" do
    @plan.update!(currency_format: CurrencyFormat.new(iso_code: "EUR", currency_symbol: "EUR", symbol_first: false, decimal_separator: ",", group_separator: ".").as_json)
    post_account("checking", 123_450)
    assert_response :created
    row = response.parsed_body.dig("data", "account")
    assert_equal "123,45EUR", row.fetch("balance_formatted")
    assert_equal "123,45EUR", row.fetch("cleared_balance_formatted")
    get "#{@path}/accounts", headers: @headers
    assert_equal "123,45EUR", response.parsed_body.dig("data", "accounts", 0, "balance_formatted")
    get "#{@path}/accounts/#{row.fetch('id')}", headers: @headers
    assert_equal "0,00EUR", response.parsed_body.dig("data", "account", "uncleared_balance_formatted")
  end

  test "missing null noninteger and nonnumeric balances fail with no partial records" do
    [ {}, { balance: nil }, { balance: 1.5 }, { balance: "12.3" }, { balance: "bad" }, { balance: true } ].each do |input|
      before = [ @plan.accounts.count, @plan.transactions.count, @plan.payees.count, @plan.categories.count ]
      post "#{@path}/accounts", params: { account: { name: "Invalid", type: "checking" }.merge(input) }, headers: @headers, as: :json
      assert_response :bad_request
      assert_equal before, [ @plan.accounts.count, @plan.transactions.count, @plan.payees.count, @plan.categories.count ]
    end
  end

  private
    def post_account(type, balance)
      post "#{@path}/accounts", params: { account: { name: "#{type} account", type: type, balance: balance } }, headers: @headers, as: :json
    end

    def month
      get "#{@path}/months/current", headers: @headers
      assert_response :ok
      response.parsed_body.dig("data", "month")
    end
end
