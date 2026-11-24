require "application_system_test_case"

# Real browser run of the budget grid: the shared field controller validates
# and keeps rejected text, a clean commit saves, and the phone layout keeps
# every amount on screen with 44px controls.
class BudgetGridSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Grid plan")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit users_budget_path(@plan.public_id)
  end

  teardown { page.driver.browser.manage.window.resize_to(1400, 1400) }

  # Stimulus connects after load; typing before that would skip the controller.
  def grid_field
    assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 1
    find_field("Assigned for Zebra fund")
  end

  # With an error showing, a long message wraps and never pushes Available or
  # any amount out of the table at desktop, tablet and phone widths.
  def assert_grid_fits_with_error(text)
    [ [ 1400, 1000 ], [ 1280, 900 ], [ 1024, 800 ], [ 390, 844 ] ].each do |width, height|
      page.driver.browser.manage.window.resize_to(width, height)
      assert_selector ".field__error", text: text
      fits = page.evaluate_script(<<~JS)
        (() => {
          const wrap = document.querySelector(".budget-grid .data-table").parentElement;
          const box = wrap.getBoundingClientRect();
          const cells = [...document.querySelectorAll(".budget-grid tbody tr:not([hidden]) td:last-child")].filter((c) => c.getClientRects().length);
          return {
            wrapFits: wrap.scrollWidth <= wrap.clientWidth + 1,
            pageFits: document.documentElement.scrollWidth <= innerWidth + 1,
            available: cells.length > 0 && cells.every((c) => { const r = c.getBoundingClientRect(); return r.right <= box.right + 1 && r.left >= box.left - 1 })
          };
        })()
      JS
      assert_equal({ "wrapFits" => true, "pageFits" => true, "available" => true }, fits, "error state overflows at #{width}px")
    end
  end

  def assigned
    @category.reload.month_category_for(Date.current.beginning_of_month).budgeted.to_i
  end

  test "Enter commits an expression and saves it" do
    field = grid_field
    field.set("10+5*2")
    field.send_keys(:enter)
    assert_text "Zebra fund assigned $20.00."
    assert_equal 20_000, assigned

    # Aborted request: outcome unknown, text kept, visible failure, Enter retries once, then it works.
    visit users_budget_path(@plan.public_id)
    field = grid_field
    page.execute_script("window.__real = window.fetch; window.__calls = 0; window.fetch = function() { window.__calls++; return Promise.reject(new TypeError('Failed to fetch')) }")
    field.set("30")
    field.send_keys(:enter)
    assert_text "Could not confirm the save"
    assert_field "Assigned for Zebra fund", with: "30"
    assert_equal 1, page.evaluate_script("window.__calls")
    assert_grid_fits_with_error("Could not confirm the save")
    page.execute_script("window.fetch = window.__real")
    find_field("Assigned for Zebra fund").send_keys(:enter)
    assert_text "Zebra fund assigned $30.00"
    assert_equal 30_000, assigned

    # Yen plan: no dollar "Saved" announcement before the server answers; one request.
    @plan.update!(currency_format: @plan.currency_format.as_json.merge("decimal_digits" => 0, "currency_symbol" => "\u00a5", "symbol_first" => true))
    visit users_budget_path(@plan.public_id)
    field = grid_field
    field.set("1200")
    # Hold the request to look at the page before the server answers.
    page.execute_script("window.__subs = 0; document.querySelectorAll('form[data-controller=submit]').forEach(f => f.addEventListener('submit', e => { window.__subs++; e.preventDefault() }))")
    field.send_keys(:enter, :enter, :tab)
    assert_equal 1, page.evaluate_script("window.__subs")
    assert_field "Assigned for Zebra fund", with: "1200"
    assert_equal "Saving", field.find(:xpath, "ancestor::div[@data-controller='field']").find("[data-field-target=status]", visible: :all).text(:all)
    visit users_budget_path(@plan.public_id)
    field = grid_field
    field.set("1200")
    field.send_keys(:enter)
    assert_text "Zebra fund assigned \u00a51,200"
    assert_equal 1_200_000, assigned
  end

  test "invalid text is kept with an inline error and nothing is saved; Escape restores" do
    field = grid_field
    field.set("0.004")
    field.send_keys(:enter)
    assert_text "Use at most 2 decimal places"
    assert_field "Assigned for Zebra fund", with: "0.004"
    assert_equal "true", find_field("Assigned for Zebra fund")["aria-invalid"]
    assert_equal 0, assigned
    find_field("Assigned for Zebra fund").send_keys(:escape)
    assert_field "Assigned for Zebra fund", with: "0.00"

    # Client and server share one amount ceiling.
    field = grid_field
    field.set("1000000000")
    field.send_keys(:enter)
    assert_text "That amount is too large"
    assert_field "Assigned for Zebra fund", with: "1000000000"
    assert_equal 0, assigned
    assert_nil AssignedExpression.parse("999999999.99").error
    assert_equal "That amount is too large", AssignedExpression.parse("1000000000").error
    assert_grid_fits_with_error("That amount is too large")
  end

  test "phone layout keeps Activity visible with 44px controls and no sideways scroll" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit users_budget_path(@plan.public_id)
    assert_selector "td[data-label=Activity]", minimum: 2, visible: true
    assert_equal false, page.evaluate_script("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    [ ".budget-grid input.field__input", ".budget-grid .btn", ".budget-grid td a" ].each do |selector|
      element = first(selector)
      assert_operator element.native.rect.height, :>=, 44, selector
    end
  end
end
