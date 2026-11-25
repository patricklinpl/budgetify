require "application_system_test_case"

# Real browser run of Undo slice 1: header buttons, enabled states, the
# keyboard shortcut, shortcut suppression in text fields and while a dialog is
# open, and a page reload.
class UndoControlsSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @plan = PlanLifecycle.create_plan(@user, name: "Undo plan")
    @account = @plan.accounts.create!(name: "Savings", type: "savings")
    writer = TransactionWriter.new(@plan)
    @reconciled = writer.persist_new!(writer.build("account_id" => @account.public_id, "date" => Date.current.iso8601,
      "amount" => 100_000, "payee_name" => "Opening", "cleared" => "reconciled"))
    visit users_sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password"
    click_button "Log in"
    assert_no_current_path users_sign_in_path
  end

  def balance = @account.reload.balance
  def register = visit(users_budget_account_transactions_path(@plan.public_id, @account.public_id))

  def add_transaction(memo, outflow)
    click_link "Add Transaction"
    assert_selector "[data-controller~=field][data-field-ready=true]"
    fill_in "Memo", with: memo
    fill_in "Outflow", with: outflow
    click_button "Save", exact: true
    assert_text "Transaction saved."
  end

  test "buttons start disabled, Undo and Redo work, a new action drops Redo and a reload disables both" do
    register
    assert_button "Undo", disabled: true
    assert_button "Redo", disabled: true
    add_transaction("first", "10")
    assert_equal 90_000, balance
    assert_button "Undo", disabled: false
    assert_button "Redo", disabled: true

    click_button "Undo"
    assert_text "Undid adding the transaction."
    assert_equal 100_000, balance
    assert_button "Redo", disabled: false
    assert_button "Undo", disabled: true

    click_button "Redo"
    assert_text "Redid adding the transaction."
    assert_equal 90_000, balance

    click_button "Undo"
    assert_text "Undid adding the transaction."
    add_transaction("second", "5")
    assert_button "Redo", disabled: true

    page.refresh
    assert_button "Undo", disabled: true
    assert_button "Redo", disabled: true
  end

  test "Ctrl+Z undoes and Ctrl+Y redoes outside text fields" do
    register
    add_transaction("kb", "10")
    assert_selector "[data-controller~=undo-shortcuts]"
    find("body").send_keys([ :control, "z" ])
    assert_text "Undid adding the transaction."
    assert_equal 100_000, balance
    find("body").send_keys([ :control, "y" ])
    assert_text "Redid adding the transaction."
    assert_equal 90_000, balance
  end

  # The controls live on the register and plan pages. A real open <dialog> and a
  # real text input are added to the page so the guard is tested where the
  # shortcut is active; without the guard these tests fail.
  test "the shortcut is inert inside a text field" do
    register
    add_transaction("field", "10")
    page.execute_script("const i = document.createElement('input'); i.id = 'probe'; document.body.appendChild(i); i.focus()")
    find("#probe").send_keys([ :control, "z" ])
    assert_no_text "Undid adding the transaction."
    assert_equal 90_000, balance
    assert_equal 1, UndoStep.where(undone: false).count
  end

  test "the shortcut is inert while any dialog is open" do
    register
    add_transaction("before dialog", "10")
    page.execute_script("const d = document.createElement('dialog'); d.id = 'probe-dialog'; d.innerHTML = '<p>Warning</p><button id=\\'probe-close\\'>Close</button>'; document.body.appendChild(d); d.showModal()")
    assert_selector "dialog[open]#probe-dialog"
    page.driver.browser.action.key_down(:control).send_keys("z").key_up(:control).perform
    assert_selector "dialog[open]#probe-dialog"
    assert_no_text "Undid adding the transaction."
    assert_equal 90_000, balance
    assert_equal 1, UndoStep.where(undone: false).count
    page.execute_script("document.getElementById('probe-dialog').close()")
    page.driver.browser.action.key_down(:control).send_keys("z").key_up(:control).perform
    assert_text "Undid adding the transaction."
    assert_equal 100_000, balance
  end

  # The reconciled-edit warning is a server-rendered section, not a <dialog>.
  # The register page carries the controls but not that section, so a section
  # with the same class is added to the page; without the guard Ctrl+Z fires.
  test "the shortcut is inert while a plan-settings warning section is on the page" do
    register
    add_transaction("warning section", "10")
    page.execute_script("const s = document.createElement('section'); s.className = 'plan-settings__warning'; s.id = 'probe-warning'; s.textContent = 'Warning'; document.body.appendChild(s)")
    assert_selector "#probe-warning"
    find("body").send_keys([ :control, "z" ])
    assert_no_text "Undid adding the transaction."
    assert_equal 90_000, balance
    assert_equal 1, UndoStep.where(undone: false).count
  end

  # Disabled and enabled controls differ by shape (dashed vs solid border), not
  # only color, and the disabled state stays a real disabled attribute.
  test "disabled Undo and Redo have a dashed border and enabled ones a solid border" do
    register
    style = ->(label) { page.evaluate_script("getComputedStyle([...document.querySelectorAll('button')].find((b) => b.textContent.trim() === '#{label}')).borderTopStyle") }
    assert_equal "dashed", style.call("Undo")
    assert_equal "dashed", style.call("Redo")
    add_transaction("shape cue", "10")
    assert_equal "solid", style.call("Undo")
    assert_equal "dashed", style.call("Redo")
    assert_button "Redo", disabled: true
  end

  test "Undo and Redo are at least 44px tall and wide at phone width" do
    page.driver.browser.manage.window.resize_to(390, 900)
    register
    %w[Undo Redo].each do |label|
      size = page.evaluate_script("(() => { const r = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === '#{label}').getBoundingClientRect(); return [r.width, r.height]; })()")
      assert_operator size[0], :>=, 44, "#{label} width #{size[0]}"
      assert_operator size[1], :>=, 44, "#{label} height #{size[1]}"
    end
    assert_equal page.evaluate_script("innerWidth"), page.evaluate_script("document.documentElement.scrollWidth")
  end

  test "Undo of a reconciled row memo edit restores it and keeps it reconciled" do
    visit edit_users_budget_account_transaction_path(@plan.public_id, @account.public_id, @reconciled.public_id)
    assert_selector "[data-controller~=field][data-field-ready=true]"
    fill_in "Memo", with: "memo only"
    click_button "Save", exact: true
    assert_text "Transaction saved."
    assert_equal "memo only", @reconciled.reload.memo
    click_button "Undo"
    assert_text "Undid the transaction edit."
    assert_nil @reconciled.reload.memo
    assert_equal "reconciled", @reconciled.cleared
  end
end
