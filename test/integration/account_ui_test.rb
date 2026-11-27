require "test_helper"

class AccountUiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = users(:one)
    post session_path, params: { email_address: @user.email_address, password: "password" }
    @plan = @user.budgets.create!(name: "Household")
    @base = "/users/budgets/#{@plan.public_id}"
  end

  teardown { Rails.cache.clear }

  test "add account form lists available types and marks loan types unavailable" do
    get "#{@base}/accounts/new"
    assert_response :ok
    assert_select "label[for=account_name]", "Account nickname"
    assert_select "select#account_type option[value=creditCard]"
    assert_select "select#account_type option[value=lineOfCredit]"
    assert_select "select#account_type option[disabled]", text: /Auto Loan \(not available yet\)/
    assert_select ".app-shell-sidebar a[href=?]", "#{@base}/accounts/new"
  end

  test "creating an account records one opening row and shows it selected" do
    assert_difference -> { @plan.accounts.count }, 1 do
      post "#{@base}/accounts", params: { account: { name: "Everyday", type: "checking", balance: "1000.50" } }
    end
    account = @plan.accounts.find_by!(name: "Everyday")
    assert_redirected_to "#{@base}?account=#{account.public_id}"
    assert_equal 1_000_500, account.balance
    assert_equal 1, account.transactions.count
    follow_redirect!
    assert_select ".app-shell-account--selected", /Everyday/
  end

  test "each invalid field is rejected with its own message and nothing is written" do
    cases = {
      { name: "", type: "checking", balance: "1" } => /account name/,
      { name: "x", type: "", balance: "1" } => /account type/,
      { name: "x", type: "autoLoan", balance: "1" } => /account type/,
      { name: "x", type: "checking", balance: "" } => /balance/,
      { name: "x", type: "checking", balance: "abc" } => /balance/,
      { name: "x", type: "checking", balance: "1e3" } => /balance/,
      { name: "x", type: "checking", balance: "1.2345" } => /balance/,
      { name: "bad\u0000name", type: "checking", balance: "1" } => /account name/
    }
    cases.each do |params, pattern|
      assert_no_difference [ -> { @plan.accounts.count }, -> { Transaction.count } ] do
        post "#{@base}/accounts", params: { account: params }
      end
      assert_response :unprocessable_entity, params.inspect
      assert_select ".plan-settings__errors[data-controller=focus]", pattern
    end
    assert_no_difference -> { @plan.accounts.count } do
      post "#{@base}/accounts", params: { account: "text" }
    end
    assert_response :unprocessable_entity
  end

  test "line of credit and credit card get a payment category and debt stays out of Ready to Assign" do
    post "#{@base}/accounts", params: { account: { name: "LOC", type: "lineOfCredit", balance: "-100" } }
    account = @plan.accounts.find_by!(name: "LOC")
    assert_equal(-100_000, account.balance)
    assert account.payment_category.present?
  end

  test "edit saves name and note, rejects a blank name, and Cancel link goes back" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Old", "type" => "checking", "balance" => 0 })
    get "#{@base}/accounts/#{account.public_id}/edit"
    assert_response :ok
    patch "#{@base}/accounts/#{account.public_id}", params: { account: { name: "New name", note: "remember" } }
    assert_redirected_to "#{@base}?account=#{account.public_id}"
    assert_equal [ "New name", "remember" ], [ account.reload.name, account.note ]
    patch "#{@base}/accounts/#{account.public_id}", params: { account: { name: " ", note: "changed" } }
    assert_response :unprocessable_entity
    assert_equal [ "New name", "remember" ], [ account.reload.name, account.note ]
  end

  test "close and reopen a tracking account: zeroing adjustment, reopen at zero" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Asset", "type" => "otherAsset", "balance" => 450_000 })
    post "#{@base}/accounts/#{account.public_id}/close"
    assert_response :redirect
    assert_equal [ true, 0, 2 ], [ account.reload.closed, account.balance, account.transactions.count ]
    post "#{@base}/accounts/#{account.public_id}/reopen"
    assert_equal [ false, 0, 2 ], [ account.reload.closed, account.balance, account.transactions.count ]
  end

  test "closing an on-budget account with a balance is refused and says why" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Cash", "type" => "checking", "balance" => 10_000 })
    get "#{@base}/accounts/#{account.public_id}/edit"
    assert_select "button[disabled]", "Close account"
    post "#{@base}/accounts/#{account.public_id}/close"
    assert_response :unprocessable_entity
    assert_select ".plan-settings__errors", /on budget/
    assert_equal [ false, 10_000 ], [ account.reload.closed, account.balance ]
  end

  test "delete is offered only for opening-only accounts and removes it immediately" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Temp", "type" => "otherLiability", "balance" => -50_000 })
    get "#{@base}/accounts/#{account.public_id}/edit"
    assert_select "form[action=?] input[name=_method][value=delete]", "#{@base}/accounts/#{account.public_id}"
    delete "#{@base}/accounts/#{account.public_id}"
    assert_redirected_to @base
    assert account.reload.deleted
    busy = Account.open!(budget: @plan, attributes: { "name" => "Busy", "type" => "otherAsset", "balance" => 1000 })
    busy.adjust_balance!(500)
    get "#{@base}/accounts/#{busy.public_id}/edit"
    assert_select "button[disabled]", "Delete account"
    delete "#{@base}/accounts/#{busy.public_id}"
    assert_response :unprocessable_entity
    assert_not busy.reload.deleted
  end

  test "another user's plan and accounts are 404 on every account route" do
    theirs = users(:two).budgets.create!(name: "Theirs")
    acct = Account.open!(budget: theirs, attributes: { "name" => "Secret", "type" => "checking", "balance" => 1 })
    other = "/users/budgets/#{theirs.public_id}"
    get "#{other}/accounts/new"
    assert_response :not_found
    post "#{other}/accounts", params: { account: { name: "x", type: "checking", balance: "1" } }
    assert_response :not_found
    get "#{other}/accounts/#{acct.public_id}/edit"
    assert_response :not_found
    # own plan, foreign account id
    get "#{@base}/accounts/#{acct.public_id}/edit"
    assert_response :not_found
    delete "#{@base}/accounts/#{acct.public_id}"
    assert_response :not_found
    assert_not acct.reload.deleted
  end

  test "register header Edit is a real link to the edit page" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Reg", "type" => "checking", "balance" => 0 })
    get "#{@base}?account=#{account.public_id}"
    assert_select "a.shell-button[href=?]", "#{@base}/accounts/#{account.public_id}/edit", text: "Edit"
  end

  test "closed accounts are listed in the sidebar and phone list as real links and stay selectable" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Old Asset", "type" => "otherAsset", "balance" => 5_000 })
    account.close!
    get "#{@base}?account=#{account.public_id}"
    assert_response :ok
    assert_select ".app-shell-sidebar details.app-shell-account-group[open] a.app-shell-account--selected[aria-current=page]", /Old Asset \(closed\)/
    assert_select ".app-shell-phone-accounts a.app-shell-phone-accounts__link", /Old Asset \(closed\)/
    assert_select ".app-shell-sidebar .app-shell-account-group-name", text: "CLOSED"
    assert_select ".app-shell-phone-accounts__group", text: "CLOSED"
  end

  test "manual adjustment UI records one adjustment for a tracking account and rejects bad input" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Home", "type" => "otherAsset", "balance" => 500_000 })
    get "#{@base}/accounts/#{account.public_id}/edit"
    assert_select "form[action=?] input#adjustment_balance", "#{@base}/accounts/#{account.public_id}/adjust"
    post "#{@base}/accounts/#{account.public_id}/adjust", params: { adjustment: { balance: "abc" } }
    assert_response :unprocessable_entity
    assert_equal 500_000, account.reload.balance
    post "#{@base}/accounts/#{account.public_id}/adjust", params: { adjustment: { balance: "450.00" } }
    assert_redirected_to "#{@base}?account=#{account.public_id}"
    assert_equal 450_000, account.reload.balance
    assert_equal 1, account.transactions.not_deleted.where(opening_balance: false).count
  end

  test "on-budget and closed accounts refuse the adjustment with a reason and write nothing" do
    checking = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
    get "#{@base}/accounts/#{checking.public_id}/edit"
    assert_select "input#adjustment_balance", false
    post "#{@base}/accounts/#{checking.public_id}/adjust", params: { adjustment: { balance: "5" } }
    assert_response :unprocessable_entity
    assert_match(/tracking accounts/, response.body)
    assert_equal 100_000, checking.reload.balance
    tracked = Account.open!(budget: @plan, attributes: { "name" => "T", "type" => "otherAsset", "balance" => 1_000 })
    tracked.close!
    post "#{@base}/accounts/#{tracked.public_id}/adjust", params: { adjustment: { balance: "5" } }
    assert_response :unprocessable_entity
    assert_equal 0, tracked.reload.balance
  end

  test "another user cannot adjust my account" do
    account = Account.open!(budget: @plan, attributes: { "name" => "Mine", "type" => "otherAsset", "balance" => 1_000 })
    delete session_path
    other = User.create!(email_address: "ui-other@example.com", password: "password123")
    post session_path, params: { email_address: other.email_address, password: "password123" }
    post "#{@base}/accounts/#{account.public_id}/adjust", params: { adjustment: { balance: "5" } }
    assert_response :not_found
    assert_equal 1_000, account.reload.balance
  end
end
