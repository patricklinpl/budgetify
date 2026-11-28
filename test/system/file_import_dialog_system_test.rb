require "application_system_test_case"

# The File Import dialog opens from the register toolbar and closes with no side
# effect. [engineering] Synthetic data; nothing is imported.
class FileImportDialogSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Import plan")
    @account = Account.open!(budget: @plan, attributes: { "name" => "Checking", "type" => "checking", "balance" => 10_000 })
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_path(@plan.public_id, account: @account.public_id)
  end

  test "File Import opens the dialog and Close dismisses it" do
    assert_selector "[data-controller~=dialog][data-dialog-ready=true]"
    click_button "File Import"
    assert_selector "dialog#file-import-dialog[open]"
    assert_field "Choose File"
    assert_button "Preview"
    click_button "Close"
    assert_no_selector "dialog#file-import-dialog[open]"
    assert_equal "File Import", page.evaluate_script("document.activeElement.textContent.trim()")
  end

  test "Escape closes the dialog and returns focus to the button" do
    assert_selector "[data-controller~=dialog][data-dialog-ready=true]"
    click_button "File Import"
    assert_selector "dialog#file-import-dialog[open]"
    find("dialog#file-import-dialog").send_keys(:escape)
    assert_no_selector "dialog#file-import-dialog[open]"
    assert_equal "File Import", page.evaluate_script("document.activeElement.textContent.trim()")
  end
end
