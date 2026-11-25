require "application_system_test_case"

# A disabled Save must look different from an enabled one in both themes
# (dark used to render them alike).
class DisabledSaveLookTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Look plan")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  %w[light dark].each do |theme|
    test "disabled Save looks different from enabled Save in the #{theme} theme" do
      visit new_users_budget_account_transaction_path(@plan.public_id, @account.public_id)
      assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 2
      page.execute_script("document.documentElement.setAttribute('data-theme','#{theme}')")
      look = "(function(){var b=[...document.querySelectorAll('form button, form input[type=submit]')].find(function(e){return (e.value||e.textContent).trim()==='Save'});var s=getComputedStyle(b);return [s.backgroundColor,s.color,s.borderTopStyle].join('|')})()"
      enabled = page.evaluate_script(look)
      find_field("Outflow").send_keys("abc", :enter)
      # Observation only: if this assertion fails, the message also carries the
      # page state (field values, aria-invalid, button disabled states, focus).
      # Same steps, same assertion, no listeners, no retry.
      with_input_diagnostics("Save") { assert_button "Save", disabled: true, exact: true }
      disabled = page.evaluate_script(look)
      assert_not_equal enabled, disabled
      assert_includes disabled, "dashed"
      # The disabled fill is the sunken surface, not the themed primary fill.
      sunken = page.evaluate_script("(function(){var d=document.createElement('div');d.style.background='var(--color-surface-sunken)';document.body.appendChild(d);var c=getComputedStyle(d).backgroundColor;d.remove();return c})()")
      assert_equal sunken, disabled.split("|").first
    end
  end
end
