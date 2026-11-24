require "application_system_test_case"

# Real browser run: a transfer is entered by typing a "To/From <account>" payee
# with native keys, saved, and the other account's register shows the matching
# row (#60 slice 4). Native key and click interactions only.
class RegisterTransferTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Transfer plan")
    @cash = @plan.accounts.create!(name: "Cash", type: "cash")
    @savings = @plan.accounts.create!(name: "Savings", type: "savings")
    group = @plan.category_groups.create!(name: "Everyday")
    @category = group.categories.create!(budget: @plan, name: "Zebra fund")
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
    visit new_users_budget_account_transaction_path(@plan.public_id, @cash.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]", minimum: 2
    install_input_log
  end

  PAYEE_STATE_JS = <<~JS
    (() => {
      const payee = document.querySelector("#transaction_payee, input[name$='[payee]']");
      const category = document.querySelector("select[name$='[category_id]'], #transaction_category_id");
      const host = document.querySelector("[data-controller~=transfer-payee]");
      const active = document.activeElement;
      return JSON.stringify({
        payee: payee ? { value: payee.value, connected: payee.isConnected, focused: payee === active } : "not found",
        category: category ? { disabled: category.disabled, value: category.value, text: category.options[category.selectedIndex] && category.options[category.selectedIndex].text } : "not found",
        controllerHost: host ? { connected: host.isConnected } : "not found",
        active: active ? active.tagName + "#" + active.id : "none"
      });
    })()
  JS

  # Observation only. Records the payee and category state around the native
  # send_keys and appends it, with the document identity and the input log, to
  # a failing expectation. Nothing is retried, replaced or weakened.
  def payee_state
    page.evaluate_script(PAYEE_STATE_JS)
  rescue => e
    "unavailable: #{e.class}"
  end

  def payee_keys(text)
    @payee_trace ||= []
    entry = { typed: text, before: { doc: doc_state, state: payee_state } }
    @payee_trace << entry
    find_field("Payee").send_keys(text)
    entry[:after] = { doc: doc_state, state: payee_state }
  end

  def with_payee_diagnostics
    yield
  rescue Minitest::Assertion, Capybara::ExpectationNotFound => e
    log = (page.evaluate_script("window.__inputLog") rescue "unavailable")
    raise e.class, "#{e.message}\nPayee trace: #{(@payee_trace || []).to_json}\nNow: #{payee_state}\nDocument now: #{doc_state}\nInput log (last 60): #{Array(log).last(60).to_json}"
  end

  test "a To/From payee saves a transfer and the other account shows the matching row" do
    assert_selector "datalist#transaction_payee_options option[value='To/From Savings']", visible: :all
    select "Zebra fund", from: "Category"
    payee_keys("To/From Savings")
    with_payee_diagnostics do
      assert_field "Category", disabled: true, with: ""
      assert_select "Category", selected: "Category not needed", disabled: true
    end
    find_field("Payee").send_keys(*Array.new(20, :backspace))
    with_payee_diagnostics { assert_no_selector "select[disabled]" }
    assert_select "Category", selected: "Zebra fund"
    assert_equal @category.public_id, find_field("Category").value
    find_field("Payee").send_keys("To/From Savings")
    find_field("Memo").send_keys("Top up")
    find_field("Outflow").send_keys("25", :enter)
    click_button "Save", exact: true
    assert_text "Transaction saved."
    assert_text "Transfer : Savings"
    assert_equal [ -25_000, 25_000 ], [ @cash.reload.balance, @savings.reload.balance ]

    visit users_budget_account_transactions_path(@plan.public_id, @savings.public_id)
    assert_text "Transfer : Cash"
    assert_text "Top up"
  end
end
