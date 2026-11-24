require "test_helper"

# Request-level checks for Credit Card Payment category tracking
# (dependent on issue #33's transaction/month semantics):
# - creating a credit account auto-creates its Credit Card Payment
#   category under "Credit Card Payments"
# - funded credit spending moves funds from the spending category into
#   the card's payment category (Ready to Assign unaffected)
# - overspent credit spending does not move (card underfunding)
# - payments (transfers into the card) spend the payment category;
#   overpaying turns it red = cash overspending
# - assigning directly to the payment category is allowed
# - a payment category_id supplied on a (sub)transaction is ignored
#   (spec: SaveTransaction.category_id / SaveSubTransaction.category_id)
class CreditCardPaymentsApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "ccpay@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Everyday", created_at: 2.months.ago)
    @group = @plan.category_groups.create!(name: "Everyday Expenses")
    @groceries = @group.categories.create!(budget: @plan, name: "Groceries")
    @checking = @plan.accounts.create!(name: "Checking", type: "checking", balance: 0)
    @month = Date.current.beginning_of_month
  end

  teardown do
    Rails.cache.clear
  end

  test "creating a credit account auto-creates its Credit Card Payment category" do
    post "/v1/plans/#{@plan.public_id}/accounts", params: { account: { name: "Visa", type: "creditCard", balance: 0 } }, headers: auth_headers, as: :json

    assert_response :created
    get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers
    groups = response.parsed_body.fetch("data").fetch("category_groups")
    payment_group = groups.find { |group| group.fetch("name") == "Credit Card Payments" }
    assert payment_group, "expected a Credit Card Payments group"
    assert_equal false, payment_group.fetch("hidden")
    categories = payment_group.fetch("categories")
    assert_equal 1, categories.size
    assert_equal "Visa", categories.first.fetch("name")
    assert_equal false, categories.first.fetch("internal")
    assert_equal 0, categories.first.fetch("budgeted")
    assert_equal 0, categories.first.fetch("activity")
    assert_equal 0, categories.first.fetch("balance")
  end

  test "checking accounts get no payment category" do
    post "/v1/plans/#{@plan.public_id}/accounts", params: { account: { name: "Wallet", type: "cash", balance: 0 } }, headers: auth_headers, as: :json

    assert_response :created
    get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers
    groups = response.parsed_body.fetch("data").fetch("category_groups")
    assert_nil groups.find { |group| group.fetch("name") == "Credit Card Payments" }
  end

  test "funded credit spending moves funds to the payment category without touching Ready to Assign" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000)
    rta_before = month_summary.fetch("to_be_budgeted")

    post_transaction(account: card, amount: -30_000, category: @groceries)

    payment = payment_category_for(card)
    assert_equal 30_000, payment.fetch("balance"), "funded credit spending should move into the payment category"
    assert_equal 30_000, payment.fetch("activity")
    assert_equal 20_000, category_balance(@groceries)
    assert_equal rta_before, month_summary.fetch("to_be_budgeted"), "the funding move must be RTA-neutral"
  end

  test "overspent credit spending does not move and never touches Ready to Assign" do
    card = create_credit_card("Visa")

    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)

    assert_equal 0, payment_category_for(card, month: last_month).fetch("balance"), "unfunded credit spending must not move into the payment category"
    assert_equal(-30_000, category_balance(@groceries, month: last_month))
    assert_equal 0, month_summary(last_month).fetch("to_be_budgeted")

    assert_equal 0, month_summary.fetch("to_be_budgeted"), "credit overspending must not reduce the following month's RTA"
    assert_equal 0, payment_category_for(card).fetch("balance"), "underfunding does not carry as payment-category debt"
  end

  test "blended month: cash overspend is attributed before credit, so credit stays funded first" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 20_000, month: last_month)
    post_transaction(account: @checking, amount: -25_000, category: @groceries, date: last_month)
    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)

    # shortfall 35_000; cash outflows 25_000 absorb it first, so 10_000 is
    # credit overspending and 20_000 of the credit spending was funded.
    assert_equal 20_000, payment_category_for(card, month: last_month).fetch("balance")
    # RTA: no income, 20_000 assigned, 25_000 cash overspend deducted.
    assert_equal(-45_000, month_summary.fetch("to_be_budgeted"))
  end

  test "a payment transfer into the card spends the payment category" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000)
    post_transaction(account: card, amount: -30_000, category: @groceries)

    post_transfer(from: @checking, to: card, amount: -30_000)

    payment = payment_category_for(card)
    assert_equal 0, payment.fetch("balance")
    assert_equal 0, payment.fetch("activity"), "funding in and payment out net to zero activity"
  end

  test "overpaying the card turns the payment category red as cash overspending" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000, month: last_month)
    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)

    post_transfer(from: @checking, to: card, amount: -40_000, date: last_month)

    assert_equal(-10_000, payment_category_for(card, month: last_month).fetch("balance"))

    # The 10_000 overpayment creates a positive card balance, adding
    # 10_000 RTA; next month's red deduction cancels that cash inflow.
    assert_equal(-50_000, month_summary.fetch("to_be_budgeted"), "red payment category is cash overspending")
    assert_equal 0, payment_category_for(card).fetch("balance"), "red resets to zero the following month"
  end

  test "positive payment balances carry forward to the next month" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000, month: last_month)
    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)
    post_transfer(from: @checking, to: card, amount: -10_000, date: last_month)

    assert_equal 20_000, payment_category_for(card).fetch("balance")
  end

  test "assigning directly to the payment category adds to it and reduces Ready to Assign" do
    card = create_credit_card("Visa")
    payment_id = payment_category_for(card).fetch("id")

    patch "/v1/plans/#{@plan.public_id}/months/#{@month.iso8601}/categories/#{payment_id}",
      params: { category: { budgeted: 15_000 } }, headers: auth_headers, as: :json

    assert_response :ok
    category = response.parsed_body.fetch("data").fetch("category")
    assert_equal 15_000, category.fetch("budgeted")
    assert_equal 15_000, category.fetch("balance")
    assert_equal(-15_000, month_summary.fetch("to_be_budgeted"))
  end

  test "a payment category_id supplied on a transaction is ignored" do
    card = create_credit_card("Visa")
    payment_id = payment_category_for(card).fetch("id")

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: card.public_id, date: @month.iso8601, amount: -5_000, category_id: payment_id } },
      headers: auth_headers, as: :json

    assert_response :created
    transaction = response.parsed_body.fetch("data").fetch("transaction")
    assert_nil transaction.fetch("category_id")
  end

  test "a payment category_id supplied on a subtransaction is ignored" do
    card = create_credit_card("Visa")
    payment_id = payment_category_for(card).fetch("id")

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: card.public_id, date: @month.iso8601, amount: -5_000,
        subtransactions: [ { amount: -5_000, category_id: payment_id } ] } },
      headers: auth_headers, as: :json

    assert_response :created
    transaction = response.parsed_body.fetch("data").fetch("transaction")
    assert_equal [ nil ], transaction.fetch("subtransactions").map { |sub| sub.fetch("category_id") }
  end

  test "payment category knowledge is stamped when credit activity changes" do
    card = create_credit_card("Visa")
    knowledge_before = plan_knowledge

    post_transaction(account: card, amount: -30_000, category: @groceries)

    get "/v1/plans/#{@plan.public_id}/categories?last_knowledge_of_server=#{knowledge_before}", headers: auth_headers
    groups = response.parsed_body.fetch("data").fetch("category_groups")
    names = groups.flat_map { |group| group.fetch("categories") }.map { |category| category.fetch("name") }
    assert_includes names, "Visa"
  end

  test "multi-card partial funding covers credit spending in entry order" do
    visa = create_credit_card("Visa")
    amex = create_credit_card("Amex")
    assign_budgeted(@groceries, 30_000, month: last_month)
    # Pool is 30_000; the earlier Visa spend is covered first, Amex gets
    # the remaining 10_000 (YNAB moves money per transaction, docs:
    # Handling Credit Cards in YNAB: An Overview).
    post_transaction(account: visa, amount: -20_000, category: @groceries, date: last_month)
    post_transaction(account: amex, amount: -20_000, category: @groceries, date: last_month + 1)

    assert_equal 20_000, payment_category_for(visa, month: last_month).fetch("balance")
    assert_equal 10_000, payment_category_for(amex, month: last_month).fetch("balance")
    # 30_000 assigned - 40_000 total spending: the 10_000 shortfall is
    # all credit overspending (cash outflows are zero).
    assert_equal(-10_000, category_balance(@groceries, month: last_month))
  end

  test "cash advance (transfer credit -> cash) raises Ready to Assign, payment category unchanged; update and delete track it" do
    card = create_credit_card("Visa")
    rta_before = month_summary.fetch("to_be_budgeted")
    payment_before = payment_category_for(card).fetch("balance")

    post "/v1/plans/#{@plan.public_id}/transactions",
      params: { transaction: { account_id: card.public_id, date: @month.iso8601, amount: -20_000, transfer_account_id: @checking.public_id } },
      headers: auth_headers, as: :json
    assert_response :created
    transaction_id = response.parsed_body.fetch("data").fetch("transaction").fetch("id")
    assert_equal rta_before + 20_000, month_summary.fetch("to_be_budgeted"), "debt inflow raises RTA (docs: Credit Card Cash Advances)"
    assert_equal payment_before, payment_category_for(card).fetch("balance"), "payment category Available remains unchanged"

    put "/v1/plans/#{@plan.public_id}/transactions/#{transaction_id}",
      params: { transaction: { amount: -30_000 } }, headers: auth_headers, as: :json
    assert_response :ok
    assert_equal rta_before + 30_000, month_summary.fetch("to_be_budgeted"), "updated amount re-derives the inflow"

    delete "/v1/plans/#{@plan.public_id}/transactions/#{transaction_id}", headers: auth_headers
    assert_response :ok
    assert_equal rta_before, month_summary.fetch("to_be_budgeted"), "deleting the transfer removes the inflow"
  end

  test "card payments and cash-to-cash transfers never change Ready to Assign (no double counting)" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000)
    post_transaction(account: card, amount: -20_000, category: @groceries)
    rta_before = month_summary.fetch("to_be_budgeted")

    post_transfer(from: @checking, to: card, amount: -20_000)
    assert_equal rta_before, month_summary.fetch("to_be_budgeted"), "a card payment moves assigned money, not new money"

    savings = @plan.accounts.create!(name: "Savings", type: "savings", balance: 0)
    post_transfer(from: @checking, to: savings, amount: -5_000)
    assert_equal rta_before, month_summary.fetch("to_be_budgeted"), "cash-to-cash transfers are not inflows"
  end

  test "refunds reverse funding once including a later refund-only month" do
    card = create_credit_card("Visa")
    assign_budgeted(@groceries, 50_000, month: last_month)
    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)
    post_transaction(account: card, amount: 10_000, category: @groceries, date: last_month + 1)
    assert_equal 20_000, payment_category_for(card, month: last_month).fetch("balance")
    post_transaction(account: card, amount: 5_000, category: @groceries)
    assert_equal(-5_000, payment_category_for(card).fetch("activity"))
    assert_equal 15_000, payment_category_for(card).fetch("balance")
  end

  test "backdated credit edits and deletion recalculate both card funding categories" do
    visa = create_credit_card("Visa")
    amex = create_credit_card("Amex")
    assign_budgeted(@groceries, 30_000, month: last_month)
    post_transaction(account: visa, amount: -20_000, category: @groceries, date: last_month)
    id = response.parsed_body.fetch("data").fetch("transaction").fetch("id")
    post_transaction(account: amex, amount: -20_000, category: @groceries, date: last_month + 1)
    put "/v1/plans/#{@plan.public_id}/transactions/#{id}",
      params: { transaction: { amount: -10_000 } }, headers: auth_headers, as: :json
    assert_response :ok
    assert_equal 10_000, payment_category_for(visa, month: last_month).fetch("balance")
    assert_equal 20_000, payment_category_for(amex, month: last_month).fetch("balance")
    delete "/v1/plans/#{@plan.public_id}/transactions/#{id}", headers: auth_headers
    assert_response :ok
    assert_equal 0, payment_category_for(visa, month: last_month).fetch("balance")
    assert_equal 20_000, payment_category_for(amex, month: last_month).fetch("balance")
  end

  test "a credit balance transfer moves neither payment funds nor Ready to Assign" do
    visa = create_credit_card("Visa")
    amex = create_credit_card("Amex")
    post_transfer(from: visa, to: amex, amount: -20_000)
    assert_equal 0, payment_category_for(visa).fetch("balance")
    assert_equal 0, payment_category_for(amex).fetch("balance")
    assert_equal 0, month_summary.fetch("to_be_budgeted")
  end

  test "payment target defaults to MF and unsupported frequency is rejected" do
    card = create_credit_card("Visa")
    category = card.payment_category
    patch "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}",
      params: { category: { goal_target: 20_000 } }, headers: auth_headers, as: :json
    assert_response :ok
    assert_equal "MF", response.parsed_body.fetch("data").fetch("category").fetch("goal_type")
    patch "/v1/plans/#{@plan.public_id}/categories/#{category.public_id}",
      params: { category: { goal_target: 20_000, goal_frequency: "monthly" } }, headers: auth_headers, as: :json
    assert_response :bad_request
  end

  test "assignment changes surface derived payment categories through delta" do
    card = create_credit_card("Visa")
    post_transaction(account: card, amount: -20_000, category: @groceries)
    knowledge = plan_knowledge
    assign_budgeted(@groceries, 20_000)
    get "/v1/plans/#{@plan.public_id}/categories?last_knowledge_of_server=#{knowledge}", headers: auth_headers
    names = response.parsed_body.fetch("data").fetch("category_groups").flat_map { |g| g.fetch("categories") }.pluck("name")
    assert_includes names, "Visa"
  end

  test "positive card balance funds cash purchases before new debt creates payment funding" do
    card = @plan.accounts.create!(name: "Positive Visa", type: "creditCard", balance: 20_000)
    assign_budgeted(@groceries, 40_000)
    post_transaction(account: card, amount: -15_000, category: @groceries)
    assert_equal 0, payment_category_for(card).fetch("balance")
    post_transaction(account: card, amount: -10_000, category: @groceries)
    assert_equal 5_000, payment_category_for(card).fetch("balance")
    assert_equal 15_000, category_balance(@groceries)
  end

  test "unfunded positive-card purchases are cash overspending only for their positive-balance portion" do
    card = @plan.accounts.create!(name: "Positive Visa", type: "creditCard", balance: 20_000)
    post_transaction(account: card, amount: -30_000, category: @groceries, date: last_month)
    assert_equal 0, payment_category_for(card).fetch("balance")
    assert_equal(-20_000, month_summary.fetch("to_be_budgeted"))
  end

  test "overpayment creates RTA cash once and withdrawing positive cash does not create it twice" do
    card = create_credit_card("Visa")
    post_transaction(account: card, amount: -10_000, category: @groceries)
    post_transfer(from: @checking, to: card, amount: -25_000)
    assert_equal 15_000, month_summary.fetch("to_be_budgeted")
    post_transfer(from: card, to: @checking, amount: -20_000)
    assert_equal 20_000, month_summary.fetch("to_be_budgeted"), "only 5000 of this withdrawal is new borrowing"
  end

  test "a refund before a purchase is included in the funded pool once" do
    card = @plan.accounts.create!(name: "Visa", type: "creditCard", balance: -50_000)
    post_transaction(account: card, amount: 10_000, category: @groceries, date: last_month)
    post_transaction(account: card, amount: -20_000, category: @groceries, date: last_month + 1)
    assert_equal 0, payment_category_for(card, month: last_month).fetch("activity")
    assert_equal(-10_000, category_balance(@groceries, month: last_month))
  end

  # MONEY-01 / MONEY-02 (issue #57, reference-observed vectors). Entry order
  # is the opposite of purchase-date order, and the earlier purchase date
  # is funded first. Same-date ties, refunds, positive balances and mixed
  # cash/card overspending are NOT covered here (MONEY-06, untested).
  test "earlier purchase date is funded first regardless of entry order across two cards" do
    card_a = create_credit_card("CardA")
    card_b = create_credit_card("CardB")
    post_transaction(account: card_a, amount: -100_000, category: @groceries, date: last_month + 19)
    post_transaction(account: card_b, amount: -100_000, category: @groceries, date: last_month + 9)

    [
      [ 150_000, 50_000, 100_000, -50_000 ],
      [ 50_000, 0, 50_000, -150_000 ],
      [ 125_000, 25_000, 100_000, -75_000 ],
      [ 200_000, 100_000, 100_000, 0 ]
    ].each do |assigned, a_available, b_available, category_available|
      assign_budgeted(@groceries, assigned, month: last_month)
      assert_equal a_available, payment_category_for(card_a, month: last_month).fetch("balance"), "CardA payment at #{assigned}"
      assert_equal b_available, payment_category_for(card_b, month: last_month).fetch("balance"), "CardB payment at #{assigned}"
      assert_equal category_available, category_balance(@groceries, month: last_month), "category available at #{assigned}"
      funded = payment_category_for(card_a, month: last_month).fetch("activity") + payment_category_for(card_b, month: last_month).fetch("activity")
      assert_equal [ assigned, 200_000 ].min, funded, "funded spending equals payment increases at #{assigned}"
    end
  end

  # Same-date ties: the reference allocation rule is unknown (#57 MONEY-06,
  # untested), so this asserts only invariants, never which card is funded.
  test "same-date two-card allocation conserves funded money regardless of creation order" do
    [ %w[CardA CardB], %w[CardB CardA] ].each_with_index do |names, index|
      category = @group.categories.create!(budget: @plan, name: "Tie #{index}")
      cards = names.map { |name| create_credit_card("#{name}#{index}") }
      cards.each { |card| post_transaction(account: card, amount: -100_000, category: category, date: last_month + 14) }

      [ 150_000, 50_000, 125_000, 200_000 ].each do |assigned|
        assign_budgeted(category, assigned, month: last_month)
        balances = cards.map { |card| payment_category_for(card, month: last_month).fetch("balance") }
        assert_equal [ assigned, 200_000 ].min, balances.sum, "funded total at #{assigned} (order #{index})"
        assert balances.all? { |balance| balance.between?(0, 100_000) }, "each card funded within its own purchase at #{assigned}: #{balances}"
        assert_equal assigned - 200_000, category_balance(category, month: last_month)
      end
    end
  end

  private
    def last_month
      @month.last_month
    end

    def create_credit_card(name)
      post "/v1/plans/#{@plan.public_id}/accounts", params: { account: { name: name, type: "creditCard", balance: 0 } }, headers: auth_headers, as: :json
      assert_response :created
      @plan.accounts.not_deleted.find_by(name: name)
    end

    def assign_budgeted(category, amount, month: @month)
      patch "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}",
        params: { category: { budgeted: amount } }, headers: auth_headers, as: :json
      assert_response :ok
    end

    def post_transaction(account:, amount:, category:, date: @month)
      post "/v1/plans/#{@plan.public_id}/transactions",
        params: { transaction: { account_id: account.public_id, date: date.iso8601, amount: amount, category_id: category.public_id } },
        headers: auth_headers, as: :json
      assert_response :created
    end

    def post_transfer(from:, to:, amount:, date: @month)
      post "/v1/plans/#{@plan.public_id}/transactions",
        params: { transaction: { account_id: from.public_id, date: date.iso8601, amount: amount, transfer_account_id: to.public_id } },
        headers: auth_headers, as: :json
      assert_response :created
    end

    def payment_category_for(card, month: @month)
      get "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{Category.not_deleted.find_by!(payment_account_id: card.id).public_id}", headers: auth_headers
      assert_response :ok
      response.parsed_body.fetch("data").fetch("category")
    end

    def category_balance(category, month: @month)
      get "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}", headers: auth_headers
      assert_response :ok
      response.parsed_body.fetch("data").fetch("category").fetch("balance")
    end

    def month_summary(month = @month)
      get "/v1/plans/#{@plan.public_id}/months/#{month.iso8601}", headers: auth_headers
      assert_response :ok
      response.parsed_body.fetch("data").fetch("month")
    end

    def plan_knowledge
      get "/v1/plans/#{@plan.public_id}/categories", headers: auth_headers
      response.parsed_body.fetch("data").fetch("server_knowledge")
    end

    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end
end
