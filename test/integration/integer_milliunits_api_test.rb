require "test_helper"

class IntegerMilliunitsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    user = User.create!(email_address: "integer-money@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @headers = { "Authorization" => "Bearer #{token}" }
    @plan = user.budgets.create!(name: "Integer money")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @group = @plan.category_groups.create!(name: "Everyday")
    @category = @group.categories.create!(budget: @plan, name: "Food", goal_target: 1000)
    @transaction = @plan.transactions.create!(account: @account, date: Date.current, amount: 0)
    @scheduled = @plan.scheduled_transactions.create!(account: @account, date_first: Date.tomorrow, date_next: Date.tomorrow, amount: 0)
    @path = "/v1/plans/#{@plan.public_id}"
  end

  teardown { Rails.cache.clear }

  test "every canonical money write rejects floats strings booleans and int64 overflow before mutation" do
    [ 1.5, "1500", true, 2**63, -(2**63) - 1 ].each do |invalid|
      requests_for(invalid).each do |method, path, body|
        before = snapshot
        public_send(method, path, params: body, headers: @headers, as: :json)
        assert_response :bad_request, "#{method} #{path} accepted #{invalid.inspect}"
        assert_equal "400", response.parsed_body.dig("error", "id")
        assert_equal "bad_request", response.parsed_body.dig("error", "name")
        assert_equal before, snapshot, "invalid money changed records or balances"
      end
    end
  end

  test "null amounts and required balances are rejected while null goal_target removes the target" do
    requests_for(nil).reject { |_method, path, _body| path == "#{@path}/categories" || path == "#{@path}/categories/#{@category.public_id}" }.each do |method, path, body|
      before = snapshot
      public_send(method, path, params: body, headers: @headers, as: :json)
      assert_response :bad_request
      assert_equal before, snapshot
    end
    patch "#{@path}/categories/#{@category.public_id}", params: { category: { goal_target: nil } }, headers: @headers, as: :json
    assert_response :ok
    assert_nil @category.reload.goal_target
  end

  test "fractional split parts cannot truncate to a matching integer sum" do
    before = snapshot
    post "#{@path}/transactions", params: { transaction: transaction_input.merge(amount: -20,
      subtransactions: [ { amount: -10.9 }, { amount: -10.9 } ]) }, headers: @headers, as: :json
    assert_response :bad_request
    assert_equal before, snapshot
  end

  test "split amounts are required and null is not an integer" do
    [ {}, { amount: nil }, { amount: "0" } ].each do |part|
      before = snapshot
      post "#{@path}/transactions", params: { transaction: transaction_input.merge(amount: 0, subtransactions: [ part ]) }, headers: @headers, as: :json
      assert_response :bad_request
      assert_equal before, snapshot
    end
  end

  test "invalid trailing bulk item leaves no first transaction or payee behind" do
    before = snapshot
    post "#{@path}/transactions", params: { transactions: [ transaction_input.merge(amount: 1000, payee_name: "No Orphan"), transaction_input.merge(amount: 1.5) ] }, headers: @headers, as: :json
    assert_response :bad_request
    assert_equal before, snapshot
    patch "#{@path}/transactions", params: { transactions: [ { id: @transaction.public_id, amount: 2000 }, { id: @transaction.public_id, amount: 2.5 } ] }, headers: @headers, as: :json
    assert_response :bad_request
    assert_equal before, snapshot
    assert_equal 0, @transaction.reload.amount
  end

  test "valid zero signed integers omitted optional amounts and import stub remain supported" do
    [ 0, -1000, 1000 ].each do |amount|
      post "#{@path}/transactions", params: { transaction: transaction_input.merge(amount: amount) }, headers: @headers, as: :json
      assert_response :created
      assert_equal amount, response.parsed_body.dig("data", "transaction", "amount")
    end
    post "#{@path}/transactions", params: { transaction: transaction_input }, headers: @headers, as: :json
    assert_response :created
    assert_equal 0, response.parsed_body.dig("data", "transaction", "amount")
    post "#{@path}/scheduled_transactions", params: { scheduled_transaction: scheduled_input }, headers: @headers, as: :json
    assert_response :created
    assert_equal 0, response.parsed_body.dig("data", "scheduled_transaction", "amount")
    post "#{@path}/transactions/import", headers: @headers, as: :json
    assert_response :created
    assert_equal [], response.parsed_body.dig("data", "transaction_ids")
  end

  test "scheduled split creation stays unsupported with integer or fractional parts" do
    [ 1, 1.5 ].each do |amount|
      before = snapshot
      post "#{@path}/scheduled_transactions", params: { scheduled_transaction: scheduled_input.merge(subtransactions: [ { amount: amount } ]) }, headers: @headers, as: :json
      assert_response :bad_request
      assert_equal before, snapshot
    end
  end

  private
    def transaction_input
      { account_id: @account.public_id, date: Date.current.iso8601 }
    end

    def scheduled_input
      { account_id: @account.public_id, date: Date.tomorrow.iso8601 }
    end

    def snapshot
      [ @plan.accounts.count, @plan.transactions.count, @plan.payees.count,
        @plan.scheduled_transactions.count, @plan.categories.count,
        @plan.money_movements.count, @plan.money_movement_groups.count,
        @plan.reload.server_knowledge, @account.reload.balance,
        @category.reload.goal_target, @category.month_categories.sum(:budgeted) ]
    end

    def requests_for(value)
      [
        [ :post, "#{@path}/accounts", { account: { name: "Money", type: "checking", balance: value } } ],
        [ :post, "#{@path}/transactions", { transaction: transaction_input.merge(amount: value, payee_name: "No Orphan") } ],
        [ :put, "#{@path}/transactions/#{@transaction.public_id}", { transaction: { amount: value } } ],
        [ :post, "#{@path}/transactions", { transactions: [ transaction_input.merge(amount: value) ] } ],
        [ :patch, "#{@path}/transactions", { transactions: [ { id: @transaction.public_id, amount: value } ] } ],
        [ :post, "#{@path}/transactions/import", { transactions: [ transaction_input.merge(amount: value) ] } ],
        [ :post, "#{@path}/transactions", { transaction: transaction_input.merge(amount: 0, subtransactions: [ { amount: value } ]) } ],
        [ :put, "#{@path}/transactions/#{@transaction.public_id}", { transaction: { subtransactions: [ { amount: value } ] } } ],
        [ :post, "#{@path}/scheduled_transactions", { scheduled_transaction: scheduled_input.merge(amount: value) } ],
        [ :put, "#{@path}/scheduled_transactions/#{@scheduled.public_id}", { scheduled_transaction: scheduled_input.merge(amount: value) } ],
        [ :patch, "#{@path}/months/current/categories/#{@category.public_id}", { category: { budgeted: value } } ],
        [ :post, "#{@path}/categories", { category: { category_group_id: @group.public_id, name: "Target", goal_target: value } } ],
        [ :patch, "#{@path}/categories/#{@category.public_id}", { category: { goal_target: value } } ]
      ]
    end
end
