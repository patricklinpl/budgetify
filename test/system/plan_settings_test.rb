require "application_system_test_case"

# Browser checks for plan settings (issue #54): Cancel keeps the saved name,
# and Fresh Start only runs after confirmation.
class PlanSettingsSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = @user.budgets.create!(name: "Household")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  test "PLAN-CANCEL-01 typing a different name then Cancel keeps the saved name" do
    visit settings_users_budget_path(@plan.public_id)
    install_input_log
    fill_in "Plan name", with: "Something else"
    diag_click(find_link("Cancel"), "Cancel link")

    with_input_diagnostics("Cancel") { assert_current_path users_budget_path(@plan.public_id) }
    with_shell_diagnostics { assert_selector ".app-shell-plan-name", text: "Household" }
    assert_equal "Household", @plan.reload.name
    visit users_budgets_path
    assert_selector ".budget-selection-name", text: "Household"
  end

  # Records clicks and dialog open/close with timestamps from page start, so a
  # failed Cancel leaves an event log instead of only "dialog still open".
  EVENT_LOG_JS = <<~JS
    window.__dialogLog = [];
    const stamp = (what) => window.__dialogLog.push(Math.round(performance.now()) + "ms " + what);
    ["showModal", "close"].forEach((name) => {
      const original = HTMLDialogElement.prototype[name];
      HTMLDialogElement.prototype[name] = function (...args) { stamp(name + " (open=" + this.open + ")"); return original.apply(this, args); };
    });
    document.addEventListener("click", (e) => stamp("click " + e.target.tagName + " '" + (e.target.textContent || "").trim().slice(0, 16) + "' ready=" + !!document.querySelector("[data-dialog-ready]")), true);
    document.addEventListener("submit", (e) => stamp("submit " + (e.target.getAttribute("action") || e.target.getAttribute("method"))), true);
  JS

  test "Fresh Start dialog Cancel creates nothing and Confirm creates the new plan" do
    visit settings_users_budget_path(@plan.public_id)
    assert_selector "[data-controller~=dialog][data-dialog-ready]"
    page.execute_script(EVENT_LOG_JS)
    install_input_log
    assert_no_difference -> { @user.budgets.count } do
      diag_click(find_button("Fresh Start…"), "Fresh Start… (open)")
      with_input_diagnostics("Fresh Start…", "Cancel") { assert_selector "dialog[open] .dialog__title", text: "Start fresh" }
      within("dialog[open]") { diag_click(find_button("Cancel"), "dialog Cancel") }
      assert page.has_no_selector?("dialog[open]"), "Cancel left the dialog open. Event log: #{page.evaluate_script('window.__dialogLog').inspect}"
      sleep 0.3
    end
    assert_current_path settings_users_budget_path(@plan.public_id)
    assert_equal "Household", @plan.reload.name

    click_button "Fresh Start…"
    within("dialog[open]") { click_button "Create fresh plan" }
    assert_text "Fresh Start created a new plan"
    assert_equal PlanLifecycle.archived_name("Household"), @plan.reload.name
    assert_equal 2, @user.budgets.count
  end

  test "Fresh Start Cancel still closes the dialog with no script connected and submits nothing" do
    visit settings_users_budget_path(@plan.public_id)
    assert_selector "[data-controller~=dialog][data-dialog-ready]"
    page.execute_script(<<~JS)
      const section = document.querySelector("[data-controller~=dialog]");
      section.removeAttribute("data-controller");
      document.getElementById("dlg-fresh-start").showModal();
    JS
    assert_selector "dialog[open]"
    page.execute_script(EVENT_LOG_JS)
    install_input_log
    assert_no_difference -> { @user.budgets.count } do
      within("dialog[open]") { diag_click(find_button("Cancel"), "dialog Cancel (no script)") }
      with_input_diagnostics("Cancel") do
        assert page.has_no_selector?("dialog[open]"), "Cancel left the dialog open with no script connected. Event log: #{page.evaluate_script('window.__dialogLog').inspect}"
      end
      sleep 0.3
    end
    assert_current_path settings_users_budget_path(@plan.public_id)
    assert_equal "Household", @plan.reload.name
  end
end
