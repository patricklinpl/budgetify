require "test_helper"

# The account page toolbar File Import button opens a dialog. [reference] The reference
# has a File Import dialog on the account toolbar that explains downloading a bank
# file first, names the formats and has a Choose File button; Link Account sits next
# to it. [engineering] This app's wording; CSV only; choosing a file is off until
# importing is built; Link Account stays off with a reason. Synthetic data.
class FileImportDialogTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "fileimport@example.com", password: "password123")
    sign_in_as(@user)
    @budget = PlanLifecycle.create_plan(@user, name: "Import plan")
    @account = Account.open!(budget: @budget, attributes: { "name" => "Checking", "type" => "checking", "balance" => 100_000 })
  end

  test "the register toolbar has an enabled File Import button wired to its dialog" do
    get users_budget_path(@budget.public_id, account: @account.public_id)
    assert_response :success
    assert_select "button[data-dialog-id=file-import-dialog]:not([disabled])", text: "File Import"
    assert_select "dialog#file-import-dialog[aria-labelledby=file-import-title]" do
      assert_select "h2#file-import-title", "File Import"
      assert_select ".dialog__body", text: /CSV/
      assert_select "button[data-dialog-close]", text: "Close"
      assert_select "button[disabled]", text: "Choose File"
    end
  end

  test "Link Account stays off and says why" do
    get users_budget_path(@budget.public_id, account: @account.public_id)
    assert_select "button[disabled][title*='provider']", text: "Link Account"
  end

  test "the dialog has no file input yet" do
    get users_budget_path(@budget.public_id, account: @account.public_id)
    assert_select "dialog#file-import-dialog input", false
  end
end
