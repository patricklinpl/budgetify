require "application_system_test_case"

# Typography. [reference] The reference app's interface text computes to Figtree
# (then Helvetica Neue, Helvetica, Arial, sans-serif) and its amounts use tabular
# figures. [engineering] Budgetify bundles Figtree (SIL OFL 1.1) and these
# assertions read the running page: the font file really loads and the computed
# family on the shell, buttons and inputs is Figtree. Synthetic data.
class TypographySystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Type plan")
    @plan.payees.create!(name: "Corner Cafe")
    @plan.payees.create!(name: "Fresh Grocer")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def first_family(selector) = page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).fontFamily").to_s.split(",").first.delete('"').strip

  test "the plan page renders in the bundled Figtree face and the font file loads" do
    visit users_budget_path(@plan.public_id)
    assert_selector "h1"
    assert_equal "Figtree", first_family(".budget-grid input[type=text], .budget-grid input:not([type=hidden])")
    assert_equal "Figtree", first_family(".budget-grid button")
    visit users_budget_payees_path(@plan.public_id)
    assert_selector "h1", text: "Payees"
    assert_equal "Figtree", first_family("body")
    assert_equal "Figtree", first_family("h1")
    assert_equal "Figtree", first_family(".payee-list__row input.field__input")
    assert_equal "Figtree", first_family(".payee-list__row button")
    page.evaluate_script("document.fonts.load('600 16px Figtree')")
    loaded = page.evaluate_script("Array.from(document.fonts).filter(function(f) { return f.status === 'loaded'; }).map(function(f) { return f.family.replace(/\"/g, ''); })")
    assert_includes loaded, "Figtree"
    assert page.evaluate_script("document.fonts.check('16px Figtree')")
  end
end
