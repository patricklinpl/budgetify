require "test_helper"

# Plan list, creation, settings and Fresh Start pages (issue #54).
class PlanSettingsUiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @plan = @user.budgets.create!(name: "Household")
  end

  test "View All Plans lists owned plans only and offers a new plan form" do
    users(:two).budgets.create!(name: "Not mine")

    get users_budgets_path

    assert_response :success
    assert_select ".budget-selection-name", "Household"
    assert_select ".budget-selection-name", text: "Not mine", count: 0
    assert_select "form[action=?] input[name='budget[name]']", users_budgets_path
  end

  test "creating a plan opens exactly that plan with default categories and no accounts" do
    assert_difference -> { @user.budgets.count }, 1 do
      post users_budgets_path, params: { budget: { name: "Trip" } }
    end
    created = @user.budgets.find_by!(name: "Trip")
    assert_redirected_to users_budget_path(created.public_id)
    follow_redirect!
    assert_select ".app-shell-plan-name", "Trip"
    assert_select ".app-shell-empty", "No accounts yet."
    assert_equal 0, created.accounts.count
    assert_equal 8, created.categories.where(internal: false).count
  end

  test "creating a plan with a blank name shows an error and creates nothing" do
    assert_no_difference -> { Budget.count } do
      post users_budgets_path, params: { budget: { name: "  " } }
    end
    assert_response :unprocessable_entity
    assert_select "#new_plan_error", /Enter a plan name/
    assert_select "input[aria-invalid=true][aria-describedby=new_plan_error]"
  end

  test "settings page shows the saved values, a Cancel link and the Fresh Start dialog" do
    get settings_users_budget_path(@plan.public_id)

    assert_response :success
    assert_select "input#budget_name[value=?]", "Household"
    assert_select "select#budget_date_format option[selected]", "MM/DD/YYYY"
    assert_select "a.btn", text: "Cancel", href: users_budget_path(@plan.public_id)
    assert_select "dialog#dlg-fresh-start .dialog__facts li", /All accounts/
    assert_select "dialog#dlg-fresh-start", /private to you/
  end

  test "saving settings persists name, date format and currency format together" do
    patch users_budget_path(@plan.public_id), params: { budget: { name: "Renamed", date_format: "YYYY-MM-DD",
      currency_format: { iso_code: "CAD", currency_symbol: "$", symbol_first: "false", display_symbol: "true",
                         decimal_separator: ",", group_separator: ".", decimal_digits: "2" } } }

    assert_redirected_to settings_users_budget_path(@plan.public_id)
    @plan.reload
    assert_equal "Renamed", @plan.name
    assert_equal "YYYY-MM-DD", @plan.date_format
    assert_equal "-300,00$", @plan.currency_format.format_milliunits(-300_000)
    follow_redirect!
    assert_select "input#budget_name[value=?]", "Renamed"
    assert_select "select#cf_dec option[selected]", ","
  end

  test "invalid settings save nothing and keep what was typed" do
    patch users_budget_path(@plan.public_id), params: { budget: { name: "Typed name", date_format: "YY-M-D",
      currency_format: { iso_code: "usd", decimal_digits: "9" } } }

    assert_response :unprocessable_entity
    assert_select ".plan-settings__errors li", minimum: 3
    assert_select "input#budget_name[value=?]", "Typed name"
    @plan.reload
    assert_equal "Household", @plan.name
    assert_equal "MM/DD/YYYY", @plan.date_format
    assert_equal CurrencyFormat.default.as_json, @plan.currency_format.as_json
  end

  test "Fresh Start creates a new plan, archives the original and opens the new plan" do
    @plan.accounts.create!(name: "Checking", type: "checking")

    assert_difference -> { @user.budgets.count }, 1 do
      post fresh_start_users_budget_path(@plan.public_id)
    end

    fresh = @user.budgets.where.not(id: @plan.id).sole
    assert_redirected_to users_budget_path(fresh.public_id)
    assert_equal "Household", fresh.name
    assert_equal PlanLifecycle.archived_name("Household"), @plan.reload.name
    assert_equal [ "Checking" ], fresh.accounts.pluck(:name)
  end

  test "malformed or control-character names are rejected without a 500" do
    assert_no_difference -> { Budget.count } do
      post users_budgets_path, params: { budget: "text" }
      assert_response :unprocessable_entity
      post users_budgets_path, params: { budget: { name: "bad\u0000name" } }
      assert_response :unprocessable_entity
      post users_budgets_path, params: { budget: { name: [ "x" ] } }
      assert_response :unprocessable_entity
    end
    patch users_budget_path(@plan.public_id), params: { budget: { name: "tab\tname" } }
    assert_response :unprocessable_entity
    patch users_budget_path(@plan.public_id), params: { budget: "text" }
    assert_response :unprocessable_entity
    assert_equal "Household", @plan.reload.name
  end

  test "Fresh Start that cannot carry a scheduled transaction shows why and changes nothing" do
    gone = @plan.accounts.create!(name: "Gone", type: "checking")
    @plan.scheduled_transactions.create!(account: gone, date_first: Date.current, date_next: Date.current, frequency: "monthly", amount: -1000)
    gone.update!(deleted: true)

    assert_no_difference -> { Budget.count } do
      post fresh_start_users_budget_path(@plan.public_id)
    end
    assert_response :unprocessable_entity
    assert_select ".plan-settings__errors", /nothing changed/
    assert_equal "Household", @plan.reload.name
  end

  test "a hostile currency symbol is saved as text and rendered escaped" do
    patch users_budget_path(@plan.public_id), params: { budget: { name: "Household", date_format: "MM/DD/YYYY",
      currency_format: { iso_code: "USD", currency_symbol: "<b>\"", symbol_first: "true", display_symbol: "true",
                         decimal_separator: ".", group_separator: ",", decimal_digits: "2" } } }
    assert_redirected_to settings_users_budget_path(@plan.public_id)
    assert_equal "<b>\"", @plan.reload.currency_format.currency_symbol

    get settings_users_budget_path(@plan.public_id)
    assert_response :success
    assert_not_includes response.body, "value=\"<b>"
    assert_includes response.body, "value=\"&lt;b&gt;&quot;\""
    assert_select "input#cf_symbol[value=?]", "<b>\""
  end

  test "another user's plan is a 404 for settings, update and Fresh Start" do
    other = users(:two).budgets.create!(name: "Theirs")

    get settings_users_budget_path(other.public_id)
    assert_response :not_found
    patch users_budget_path(other.public_id), params: { budget: { name: "Mine" } }
    assert_response :not_found
    assert_no_difference -> { Budget.count } do
      post fresh_start_users_budget_path(other.public_id)
    end
    assert_response :not_found
    assert_equal "Theirs", other.reload.name
  end
end
