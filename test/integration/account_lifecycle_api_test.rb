require "test_helper"

class AccountLifecycleApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "account-lifecycle@example.com", password: "password123")
    token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Lifecycle")
    @headers = { "Authorization" => "Bearer #{token}" }
    @path = "/v1/plans/#{@plan.public_id}"
  end

  teardown { Rails.cache.clear }

  test "tracking balance change records one auditable Manual Balance Adjustment outside Ready to Assign" do
    id = create("otherAsset", 500_000)
    patch_account(id, balance: 450_000)
    assert_response :ok
    assert_equal 450_000, response.parsed_body.dig("data", "account", "balance")
    account = @plan.accounts.find_by!(public_id: id)
    entry = account.transactions.not_deleted.where(opening_balance: false).sole
    assert_equal(-50_000, entry.amount)
    assert_equal "Manual Balance Adjustment", entry.payee.name
    assert_nil entry.category
    assert_equal 2, account.transactions.not_deleted.count
    assert_equal 0, month.fetch("to_be_budgeted")
    patch_account(id, balance: 450_000)
    assert_equal 2, account.transactions.not_deleted.count
  end

  test "closing a nonzero tracking account zeroes it, reopen returns 0, zero close adds nothing" do
    id = create("otherAsset", 450_000)
    patch_account(id, closed: true)
    assert_response :ok
    row = response.parsed_body.dig("data", "account")
    assert_equal [ true, 0 ], [ row["closed"], row["balance"] ]
    account = @plan.accounts.find_by!(public_id: id)
    assert_equal [ 450_000, -450_000 ], account.transactions.not_deleted.order(:id).pluck(:amount)
    patch_account(id, closed: false)
    row = response.parsed_body.dig("data", "account")
    assert_equal [ false, 0 ], [ row["closed"], row["balance"] ]
    patch_account(id, closed: true)
    patch_account(id, closed: false)
    assert_equal 2, account.transactions.not_deleted.count
  end

  test "on-budget accounts refuse adjustment and nonzero close without writing" do
    id = create("checking", 100_000)
    patch_account(id, balance: 50_000)
    assert_response :unprocessable_entity
    patch_account(id, closed: true)
    assert_response :unprocessable_entity
    account = @plan.accounts.find_by!(public_id: id)
    assert_equal [ 100_000, false, 1 ], [ account.balance, account.closed, account.transactions.not_deleted.count ]
  end

  test "name and note update, malformed payloads return 400 and write nothing" do
    id = create("checking", 0)
    patch_account(id, name: "Renamed", note: "memo text")
    assert_response :ok
    row = response.parsed_body.dig("data", "account")
    assert_equal [ "Renamed", "memo text" ], [ row["name"], row["note"] ]
    assert_equal "Transfer : Renamed", @plan.payees.not_deleted.find_by!(public_id: row["transfer_payee_id"]).name
    [ { name: "  " }, { name: 5 }, { note: 5 }, { closed: "yes" }, { balance: "9" } ].each do |bad|
      patch_account(id, **bad)
      assert_response :bad_request, bad.inspect.to_s
    end
    patch "#{@path}/accounts/#{id}", params: { nope: 1 }, headers: @headers, as: :json
    assert_response :bad_request
    assert_equal "Renamed", @plan.accounts.find_by!(public_id: id).name
  end

  test "opening-only tracking liability deletes immediately with its opening row, others unchanged" do
    keep = create("otherAsset", 300_000)
    id = create("otherLiability", -50_000)
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :ok
    assert response.parsed_body.dig("data", "account", "deleted")
    get "#{@path}/accounts/#{id}", headers: @headers
    assert_response :not_found
    assert_equal 0, @plan.accounts.find_by!(public_id: id).transactions.not_deleted.count
    get "#{@path}/accounts/#{keep}", headers: @headers
    assert_equal 300_000, response.parsed_body.dig("data", "account", "balance")
    assert_equal 0, @plan.payees.not_deleted.where("name LIKE ?", "Transfer : #{@plan.accounts.find_by!(public_id: id).name}").count
  end

  test "opening-only on-budget deletion removes its Ready to Assign funding" do
    id = create("checking", 100_000)
    assert_equal 100_000, month.fetch("to_be_budgeted")
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :ok
    assert_equal 0, month.fetch("to_be_budgeted")
  end

  test "line of credit opens at negative balance with a payment category and deletes with it" do
    id = create("lineOfCredit", -100_000)
    assert_response :created
    account = @plan.accounts.find_by!(public_id: id)
    assert_equal(-100_000, account.balance)
    assert_equal 0, month.fetch("to_be_budgeted")
    assert account.payment_category.present?
    cat = account.payment_category
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :ok
    assert cat.reload.deleted
  end

  test "deletion with additional history is refused and nothing changes" do
    id = create("otherAsset", 500_000)
    patch_account(id, balance: 450_000)
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :unprocessable_entity
    assert_match(/transactions/, response.parsed_body.dig("error", "detail"))
    account = @plan.accounts.find_by!(public_id: id)
    assert_equal [ false, 450_000 ], [ account.deleted, account.balance ]
  end

  test "other users cannot reach an account" do
    id = create("checking", 0)
    other = User.create!(email_address: "other-lifecycle@example.com", password: "password123")
    headers = { "Authorization" => "Bearer #{other.sessions.create!(ip_address: "127.0.0.1", user_agent: "t").generate_api_token!}" }
    patch "#{@path}/accounts/#{id}", params: { account: { name: "x" } }, headers: headers, as: :json
    assert_response :not_found
    delete "#{@path}/accounts/#{id}", headers: headers
    assert_response :not_found
  end

  test "loan types stay unavailable on create" do
    post "#{@path}/accounts", params: { account: { name: "L", type: "autoLoan", balance: 0 } }, headers: @headers, as: :json
    assert_response :bad_request
  end

  private
    def create(type, balance)
      post "#{@path}/accounts", params: { account: { name: "#{type} #{SecureRandom.hex(2)}", type: type, balance: balance } }, headers: @headers, as: :json
      assert_response :created
      response.parsed_body.dig("data", "account", "id")
    end

    def patch_account(id, **fields)
      patch "#{@path}/accounts/#{id}", params: { account: fields }, headers: @headers, as: :json
    end

    def month
      get "#{@path}/months/current", headers: @headers
      response.parsed_body.dig("data", "month")
    end

  test "balance change on a closed account is refused until it is reopened" do
    id = create("otherAsset", 100_000)
    patch_account(id, closed: true)
    assert_response :ok
    account = @plan.accounts.find_by!(public_id: id)
    count = account.transactions.not_deleted.count
    patch_account(id, balance: 70_000)
    assert_response :unprocessable_entity
    assert_match(/Reopen/, response.parsed_body.dig("error", "detail"))
    assert_equal [ 0, count ], [ account.reload.balance, account.transactions.not_deleted.count ]
    patch_account(id, closed: false, balance: 70_000)
    assert_response :ok
    assert_equal [ false, 70_000 ], [ account.reload.closed, account.balance ]
  end

  test "deleting an opening-only card is refused while its payment category holds assigned money" do
    id = create("creditCard", 0)
    account = @plan.accounts.find_by!(public_id: id)
    category = account.payment_category
    category.month_categories.create!(month: Date.current.beginning_of_month, budgeted: 25_000)
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :unprocessable_entity
    assert_match(/assigned/, response.parsed_body.dig("error", "detail"))
    assert_equal [ false, false ], [ account.reload.deleted, category.reload.deleted ]
    category.month_categories.update_all(budgeted: 0)
    delete "#{@path}/accounts/#{id}", headers: @headers
    assert_response :ok
  end

  test "unknown or immutable fields are rejected with 400 and nothing changes" do
    id = create("checking", 0)
    [ { type: "savings" }, { on_budget: false }, { name: "Renamed", deleted: true }, { transfer_payee_id: "x" } ].each do |bad|
      patch_account(id, **bad)
      assert_response :bad_request, bad.inspect
      assert_match(/Unsupported account fields/, response.parsed_body.dig("error", "detail"))
    end
    account = @plan.accounts.find_by!(public_id: id)
    assert_equal [ "checking", true ], [ account.type, account.on_budget ]
    assert_not_equal "Renamed", account.name
  end
end
