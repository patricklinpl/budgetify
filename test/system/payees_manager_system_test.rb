require "application_system_test_case"

# #65 payees manager in a real browser, normal interaction only. [engineering] The
# rename form has an explicit Save button and Enter also submits. The reference
# showed typing then Done did not commit, so both routes are asserted to commit.
# Synthetic data.
class PayeesManagerSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Payee system plan")
    @cafe = @plan.payees.create!(name: "Corner Cafe")
    @plan.payees.create!(name: "Fresh Grocer")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_payees_path(@plan.public_id)
  end

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  test "typing then clicking Save commits and the name is kept after a reload" do
    field = find_field("Name of payee Corner Cafe")
    field.fill_in(with: "Harbour Cafe")
    within(".payee-list__row", text: "Corner Cafe") { click_button "Save" }
    assert_text "Payee renamed to Harbour Cafe."
    visit users_budget_payees_path(@plan.public_id)
    assert_field "Name of payee Harbour Cafe", with: "Harbour Cafe"
  end

  test "typing then Enter commits" do
    field = find_field("Name of payee Fresh Grocer")
    field.fill_in(with: "Market Stall")
    field.send_keys(:enter)
    assert_text "Payee renamed to Market Stall."
    assert_equal "Market Stall", @plan.payees.find_by!(name: "Market Stall").name
  end

  test "the page does not scroll sideways at 390px" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_payees_path(@plan.public_id)
    assert_field "Name of payee Corner Cafe"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth")
  end
end
