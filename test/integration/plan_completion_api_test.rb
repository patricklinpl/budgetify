require "test_helper"

class PlanCompletionApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "plan-completion@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Complete plan")
    @headers = { "Authorization" => "Bearer #{@token}" }
  end

  teardown { Rails.cache.clear }

  test "populated plan embeddings contain live accounts and omit tombstones" do
    account = @plan.accounts.create!(name: "Cash", type: "cash", balance: 12_340)
    removed = @plan.accounts.create!(name: "Old", type: "checking", deleted: true)
    other = @user.budgets.create!(name: "Other")
    other.accounts.create!(name: "Private", type: "checking")
    get "/v1/plans", params: { include_accounts: true }, headers: @headers
    assert_response :ok
    row = response.parsed_body.dig("data", "plans").find { |p| p["id"] == @plan.public_id }
    assert_equal [ account.public_id ], row.fetch("accounts").map { |a| a.fetch("id") }
    get "/v1/plans/#{@plan.public_id}", params: { include_accounts: true }, headers: @headers
    assert_response :ok
    assert_equal [ account.public_id ], response.parsed_body.dig("data", "plan", "accounts").map { |a| a.fetch("id") }
    get "/v1/plans/#{@plan.public_id}", headers: @headers
    assert_not response.parsed_body.dig("data", "plan").key?("accounts")
    assert removed.deleted?
  end

  test "month bounds agree with available month detail including historical activity" do
    account = @plan.accounts.create!(name: "Cash", type: "cash")
    earlier = Date.current.beginning_of_month.prev_month(3)
    category = @plan.categories.find_by!(internal: true)
    category.month_categories.create!(month: earlier, budgeted: 0, activity: 1000)
    @plan.transactions.create!(account: account, date: earlier, amount: 1000, category: category)
    get "/v1/plans/#{@plan.public_id}", headers: @headers
    assert_equal earlier.iso8601, response.parsed_body.dig("data", "plan", "first_month")
    assert_equal Date.current.beginning_of_month.iso8601, response.parsed_body.dig("data", "plan", "last_month")
    get "/v1/plans/#{@plan.public_id}/months/#{earlier.iso8601}", headers: @headers
    assert_response :ok
    get "/v1/plans/#{@plan.public_id}/months/#{earlier.prev_month.iso8601}", headers: @headers
    assert_response :not_found
  end

  test "child writes update plan metadata and global delta without read mutations" do
    before = @plan.reload.updated_at
    knowledge = @user.reload.server_knowledge
    travel_to 2.minutes.from_now do
      @plan.accounts.create!(name: "New", type: "checking")
      get "/v1/plans", params: { last_knowledge_of_server: knowledge }, headers: @headers
      assert_response :ok
      rows = response.parsed_body.dig("data", "plans")
      assert_equal [ @plan.public_id ], rows.map { |p| p.fetch("id") }
      assert_operator Time.iso8601(rows.first.fetch("last_modified_on")), :>, before
      stamp = @plan.reload.updated_at
      k = @user.reload.server_knowledge
      get "/v1/plans/#{@plan.public_id}", headers: @headers
      get "/v1/plans/#{@plan.public_id}/months/current", headers: @headers
      assert_equal stamp, @plan.reload.updated_at
      assert_equal k, @user.reload.server_knowledge
    end
  end
end
