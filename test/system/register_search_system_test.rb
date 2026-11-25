require "application_system_test_case"

# #62 register search in a real browser, normal user interaction only: type, read
# the field back, then submit with Enter or with the Search button, and assert the
# navigation and the listed rows. [engineering] The reference only showed that
# typing alone does not filter; submit behavior is asserted here for this app.
class RegisterSearchSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Search plan")
    @account = Account.open!(budget: @plan, attributes: { "name" => "Savings", "type" => "savings", "balance" => 45_000 })
    writer = TransactionWriter.new(@plan)
    [ [ "Recurrence A", Date.current ], [ "Recurrence B", Date.current - 1 ], [ "Corner Shop", Date.current.beginning_of_month - 3 ] ].each_with_index do |(payee, date), index|
      writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => date.iso8601,
        "amount" => -(index + 1) * 1000, "payee_name" => payee, "cleared" => "uncleared"))
    end
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_account_transactions_path(@plan.public_id, @account.public_id)
  end

  def payees = all("tbody tr td[data-label=Payee]").map(&:text)

  test "typing alone does not filter, then Enter submits the search" do
    field = find_field("Search payee")
    field.send_keys("Recurrence")
    assert_equal "Recurrence", field.value
    assert_equal 4, all("tbody tr").size
    assert_no_current_path(/q=/)
    field.send_keys(:enter)
    assert_current_path(/q=Recurrence/)
    assert_selector ".register-page__hidden", text: "2 transactions hidden by filters"
    assert_equal [ "Recurrence A", "Recurrence B" ], payees
    assert_equal "Recurrence", find_field("Search payee").value
  end

  test "the Search button submits, a date chip keeps the search, and Clear search restores the rows" do
    field = find_field("Search payee")
    field.send_keys("Recurrence")
    assert_equal "Recurrence", field.value
    click_button "Search"
    assert_current_path(/q=Recurrence/)
    assert_equal [ "Recurrence A", "Recurrence B" ], payees
    click_link "This month"
    assert_current_path(/period=this_month/)
    assert_current_path(/q=Recurrence/)
    assert_selector "nav[aria-label=Dates] a[aria-current=true]", text: "This month"
    assert_equal [ "Recurrence A", "Recurrence B" ], payees
    click_link "Clear search"
    assert_no_current_path(/q=/)
    assert_selector "nav[aria-label=Dates] a[aria-current=true]", text: "This month"
    assert_equal 3, all("tbody tr").size
  end
end
