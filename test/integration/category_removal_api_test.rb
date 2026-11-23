require "test_helper"

class CategoryRemovalApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "cat-removal@example.com", password: "password123")
    token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Removal")
    @headers = { "Authorization" => "Bearer #{token}" }
    @path = "/v1/plans/#{@plan.public_id}"
    @account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 1_000_000 })
    @month = Date.current.beginning_of_month
  end

  teardown { Rails.cache.clear }

  test "CAT-03 an empty category deletes without a replacement" do
    group = @plan.category_groups.create!(name: "Misc")
    category = group.categories.create!(budget: @plan, name: "Empty")
    delete "#{@path}/categories/#{category.public_id}", headers: @headers
    assert_response :ok
    assert category.reload.deleted
  end

  test "CAT-04 history needs a replacement, lists the impact, and migration moves everything" do
    group = @plan.category_groups.create!(name: "Needs")
    source = group.categories.create!(budget: @plan, name: "Source")
    destination = group.categories.create!(budget: @plan, name: "Destination")
    2.times { spend(source, -100_000) }
    assign(source, 200_000)
    before_rta = month_rta

    delete "#{@path}/categories/#{source.public_id}", headers: @headers
    assert_response :unprocessable_entity
    impact = response.parsed_body.fetch("impact")
    assert_equal [ 2, 200_000, -200_000, 0 ], impact.values_at("transactions", "assigned", "activity", "available")
    assert_not source.reload.deleted
    assert_equal 2, Transaction.not_deleted.where(category_id: source.id).count

    delete "#{@path}/categories/#{source.public_id}", params: { replacement_category_id: destination.public_id }, headers: @headers
    assert_response :ok
    assert source.reload.deleted
    row = MonthCategory.find_by!(category_id: destination.id, month: @month)
    assert_equal [ 200_000, -200_000 ], [ row.budgeted, row.activity ]
    assert_equal 0, MonthCategory.where(category_id: source.id).count
    assert_equal 2, Transaction.not_deleted.where(category_id: destination.id).count
    assert_equal before_rta, month_rta
    assert_equal 800_000, @account.reload.balance
  end

  test "scheduled items and money movements follow the replacement" do
    group = @plan.category_groups.create!(name: "G")
    source = group.categories.create!(budget: @plan, name: "S")
    destination = group.categories.create!(budget: @plan, name: "D")
    scheduled = @plan.scheduled_transactions.create!(account: @account, category: source, date_first: Date.current, date_next: Date.current, frequency: "monthly", amount: -5000)
    delete "#{@path}/categories/#{source.public_id}", headers: @headers
    assert_response :unprocessable_entity
    assert_equal 1, response.parsed_body.dig("impact", "scheduled_transactions")
    delete "#{@path}/categories/#{source.public_id}", params: { replacement_category_id: destination.public_id }, headers: @headers
    assert_response :ok
    assert_equal destination.id, scheduled.reload.category_id
  end

  test "assigned money with no history needs explicit confirmation and returns to Ready to Assign" do
    group = @plan.category_groups.create!(name: "Temp")
    category = group.categories.create!(budget: @plan, name: "Twelve")
    before = month_rta
    assign(category, 12_000)
    assert_equal before - 12_000, month_rta
    delete "#{@path}/categories/#{category.public_id}", headers: @headers
    assert_response :unprocessable_entity
    assert_match(/Ready to Assign/, response.parsed_body.dig("error", "detail"))
    assert_equal before - 12_000, month_rta
    delete "#{@path}/categories/#{category.public_id}", params: { return_assigned: "true" }, headers: @headers
    assert_response :ok
    assert_equal before, month_rta
  end

  test "CAT-06 deleting a group migrates all four categories into one replacement outside the group" do
    wants = @plan.category_groups.create!(name: "Wants")
    four = %w[A B C D].map { |n| wants.categories.create!(budget: @plan, name: n) }
    other = @plan.category_groups.create!(name: "Other")
    groceries = other.categories.create!(budget: @plan, name: "Groceries")
    assign(groceries, 30_000)
    spend(four.first, -33_210)
    assign(four.first, 13_210)
    before_rta = month_rta

    delete "#{@path}/category_groups/#{wants.public_id}", headers: @headers
    assert_response :unprocessable_entity
    assert_equal 4, response.parsed_body.dig("impact", "categories")
    delete "#{@path}/category_groups/#{wants.public_id}", params: { replacement_category_id: four.last.public_id }, headers: @headers
    assert_response :unprocessable_entity, "replacement inside the group is refused"
    assert_not wants.reload.deleted

    delete "#{@path}/category_groups/#{wants.public_id}", params: { replacement_category_id: groceries.public_id }, headers: @headers
    assert_response :ok
    assert wants.reload.deleted
    assert four.all? { |c| c.reload.deleted }
    row = MonthCategory.find_by!(category_id: groceries.id, month: @month)
    assert_equal [ 43_210, -33_210 ], [ row.budgeted, row.activity ]
    assert_equal 10_000, row.budgeted + row.activity
    assert_equal before_rta, month_rta
    assert_equal 1_000_000 - 33_210, @account.reload.balance
  end

  test "payment, internal, foreign and deleted targets are refused and nothing changes" do
    card = Account.open!(budget: @plan, attributes: { "name" => "Card", "type" => "creditCard", "balance" => 0 })
    group = @plan.category_groups.create!(name: "G")
    category = group.categories.create!(budget: @plan, name: "C")
    delete "#{@path}/categories/#{card.payment_category.public_id}", headers: @headers
    assert_response :unprocessable_entity
    internal = @plan.categories.find_by!(internal: true, name: Budget::INFLOW_CATEGORY_NAME)
    delete "#{@path}/categories/#{internal.public_id}", headers: @headers
    assert_response :unprocessable_entity
    spend(category, -1000)
    [ card.payment_category, internal ].each do |bad|
      delete "#{@path}/categories/#{category.public_id}", params: { replacement_category_id: bad.public_id }, headers: @headers
      assert_response :unprocessable_entity
    end
    theirs = User.create!(email_address: "other-removal@example.com", password: "password123").budgets.create!(name: "T")
    foreign = theirs.category_groups.create!(name: "F").categories.create!(budget: theirs, name: "X")
    delete "#{@path}/categories/#{category.public_id}", params: { replacement_category_id: foreign.public_id }, headers: @headers
    assert_response :bad_request
    delete "#{@path}/categories/#{category.public_id}", params: { replacement_category_id: category.public_id }, headers: @headers
    assert_response :unprocessable_entity
    assert_not category.reload.deleted
    assert_equal 1, Transaction.not_deleted.where(category_id: category.id).count
  end

  test "CAT-02 and CAT-05 rename, hide and unhide a category and a group" do
    group = @plan.category_groups.create!(name: "Fun")
    category = group.categories.create!(budget: @plan, name: "Games")
    patch "#{@path}/categories/#{category.public_id}", params: { category: { name: "Gaming", hidden: true } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [ "Gaming", true ], response.parsed_body.dig("data", "category").values_at("name", "hidden")
    patch "#{@path}/categories/#{category.public_id}", params: { category: { hidden: false } }, headers: @headers, as: :json
    assert_equal false, response.parsed_body.dig("data", "category", "hidden")
    patch "#{@path}/category_groups/#{group.public_id}", params: { category_group: { name: "Play", hidden: true } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [ "Play", true ], response.parsed_body.dig("data", "category_group").values_at("name", "hidden")
    patch "#{@path}/category_groups/#{group.public_id}", params: { category_group: { hidden: false } }, headers: @headers, as: :json
    assert_equal false, response.parsed_body.dig("data", "category_group", "hidden")
  end

  test "replacement in a deleted or hidden group, or hidden itself, is refused for category and group delete" do
    source_group = @plan.category_groups.create!(name: "Src")
    source = source_group.categories.create!(budget: @plan, name: "S")
    gone_group = @plan.category_groups.create!(name: "Gone")
    in_gone = gone_group.categories.create!(budget: @plan, name: "InGone")
    gone_group.update!(deleted: true)
    hidden_group = @plan.category_groups.create!(name: "Hid", hidden: true)
    in_hidden_group = hidden_group.categories.create!(budget: @plan, name: "InHid")
    hidden_cat = @plan.category_groups.create!(name: "Vis").categories.create!(budget: @plan, name: "Quiet", hidden: true)
    spend(source, -1000)
    [ in_gone, in_hidden_group, hidden_cat ].each do |bad|
      delete "#{@path}/categories/#{source.public_id}", params: { replacement_category_id: bad.public_id }, headers: @headers
      assert_response :unprocessable_entity
      delete "#{@path}/category_groups/#{source_group.public_id}", params: { replacement_category_id: bad.public_id }, headers: @headers
      assert_response :unprocessable_entity
    end
    assert_not source.reload.deleted
    assert_not source_group.reload.deleted
    assert_equal 1, Transaction.not_deleted.where(category_id: source.id).count
  end

  test "a category with a target is refused until the target is removed, and nothing changes" do
    group = @plan.category_groups.create!(name: "Goals")
    category = group.categories.create!(budget: @plan, name: "Saving", goal_type: "NEED", goal_target: 50_000)
    other = group.categories.create!(budget: @plan, name: "Other")
    delete "#{@path}/categories/#{category.public_id}", headers: @headers
    assert_response :unprocessable_entity
    assert_equal 1, response.parsed_body.dig("impact", "targets")
    delete "#{@path}/categories/#{category.public_id}", params: { replacement_category_id: other.public_id }, headers: @headers
    assert_response :unprocessable_entity
    delete "#{@path}/category_groups/#{group.public_id}", headers: @headers
    assert_response :unprocessable_entity
    assert_not category.reload.deleted
    assert_equal 50_000, category.goal_target
    patch "#{@path}/categories/#{category.public_id}", params: { category: { goal_target: nil } }, headers: @headers, as: :json
    assert_response :ok
    delete "#{@path}/categories/#{category.public_id}", headers: @headers
    assert_response :ok
  end

  test "unknown ids and other users' resources are 404" do
    delete "#{@path}/categories/nope", headers: @headers
    assert_response :not_found
    delete "#{@path}/category_groups/nope", headers: @headers
    assert_response :not_found
    other_token = User.create!(email_address: "third-removal@example.com", password: "password123").sessions.create!(ip_address: "127.0.0.1", user_agent: "t").generate_api_token!
    group = @plan.category_groups.create!(name: "Mine")
    delete "#{@path}/category_groups/#{group.public_id}", headers: { "Authorization" => "Bearer #{other_token}" }
    assert_response :not_found
    assert_not group.reload.deleted
  end

  private
    def assign(category, amount)
      row = MonthCategory.find_or_initialize_by(category: category, month: @month)
      row.budgeted = row.budgeted.to_i + amount
      row.save!
    end

    def spend(category, amount)
      payee = @plan.payees.create!(name: "Shop #{SecureRandom.hex(3)}")
      txn = @plan.transactions.create!(account: @account, payee: payee, category: category, date: Date.current, amount: amount, cleared: "cleared", approved: true)
      txn.apply_amounts!(+1)
    end

    def month_rta
      get "#{@path}/months/current", headers: @headers
      response.parsed_body.dig("data", "month", "to_be_budgeted")
    end
end
