require "application_system_test_case"

# Real-browser behavior of the #71 primitives on the /ui/dialogs preview page.
#
# Labels used in every test name:
#   [reference] behavior named in #71's observed conventions (desktop captures).
#   [engineering] a Budgetify contract with no reference evidence behind it.
# The preview route is not mounted in production, so none of this is proof of a
# production flow. Production dialogs are covered by plan_settings_test (Cancel,
# Fresh Start) and reconciled_row_warning_test (DLG-07 cancel keeps the editor).
class DialogPrimitivesSystemTest < ApplicationSystemTestCase
  setup do
    visit ui_dialogs_path
    assert_selector "[data-controller~=dialog][data-dialog-ready]"
  end

  def open_dialog(label) = click_button(label)

  test "DLG-01 [engineering] Escape closes only the top dialog and the editor keeps its typed text" do
    open_dialog "Editor with warning"
    fill_in "Memo", with: "typed text"
    click_button "Save (reconciled)"
    assert_selector "dialog#dlg-warn[open]"
    page.send_keys :escape
    assert_no_selector "dialog#dlg-warn[open]"
    assert_selector "dialog#dlg-editor[open]"
    assert_equal "typed text", find_field("Memo").value
  end

  test "DLG-01 [engineering] backdrop click closes the dismiss dialog and is ignored by the block dialog" do
    open_dialog "Basic dialog"
    page.execute_script("document.getElementById('dlg-basic').dispatchEvent(new MouseEvent('click', { bubbles: true }))")
    assert_no_selector "dialog#dlg-basic[open]"
    open_dialog "Editor with warning"
    page.execute_script("document.getElementById('dlg-editor').dispatchEvent(new MouseEvent('click', { bubbles: true }))")
    assert_selector "dialog#dlg-editor[open]"
  end

  test "DLG-01 [engineering] Tab and Shift+Tab stay inside the open dialog" do
    open_dialog "Basic dialog"
    inside = "document.activeElement.closest('dialog#dlg-basic') !== null"
    6.times do
      page.send_keys :tab
      assert page.evaluate_script(inside), "Tab left the dialog"
    end
    6.times do
      page.send_keys [ :shift, :tab ]
      assert page.evaluate_script(inside), "Shift+Tab left the dialog"
    end
  end

  test "DLG-02 [engineering] confirm stays disabled until the required choice is made and Cancel leaves the page untouched" do
    open_dialog "Delete with consequences"
    within("dialog#dlg-migrate") do
      assert_selector "li", text: "42 transactions use this category"
      assert_selector "button[data-dialog-confirm][disabled]"
      select "Groceries", from: "Move them to"
      assert_no_selector "button[data-dialog-confirm][disabled]"
      select "Choose a category", from: "Move them to"
      assert_selector "button[data-dialog-confirm][disabled]"
      click_button "Cancel"
    end
    assert_no_selector "dialog[open]"
  end

  test "DLG-03 [reference] inline confirm asks in place, Cancel restores the row, Delete marks it done" do
    counts = -> { [ Budget.count, Account.count, Transaction.count ] }
    before = counts.call
    page.execute_script(<<~JS)
      window.__netCalls = 0;
      const realFetch = window.fetch;
      window.fetch = function(...args) { window.__netCalls += 1; return realFetch.apply(this, args); };
      const realSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) { window.__netCalls += 1; return realSend.apply(this, args); };
    JS
    within(".inline-confirm") do
      click_button "Delete"
      assert_selector "[role=alert]", text: "Delete this view?"
      click_button "Cancel"
      assert_no_selector "[role=alert]"
      assert_button "Delete"
      assert_no_selector ".inline-confirm--done", visible: :all
      click_button "Delete"
      within("[data-inline-confirm-target=confirm]") { click_button "Delete" }
    end
    assert_selector ".inline-confirm.inline-confirm--done"
    # Preview-only effect: no request is sent and no real data changes.
    assert_equal before, counts.call
    assert_equal 0, page.evaluate_script("window.__netCalls")
  end

  test "DLG-04 [reference] menu closes on Escape and outside click; [engineering] arrows move focus and toggles flip" do
    click_button "View options"
    assert_selector "[role=menu]"
    page.send_keys :arrow_down
    assert_equal "Show hidden categories", page.evaluate_script("document.activeElement.textContent.trim()")
    page.send_keys :end
    assert_equal "Delete view", page.evaluate_script("document.activeElement.textContent.trim()")
    page.send_keys :home
    assert_equal "Show progress bars", page.evaluate_script("document.activeElement.textContent.trim()")
    click_button "Show hidden categories"
    assert_selector "[role=menuitemcheckbox][aria-checked=true]", text: "Show hidden categories"
    page.send_keys :escape
    assert_no_selector "[role=menu]"
    click_button "View options"
    assert_selector "[role=menu]"
    find("h1").click
    assert_no_selector "[role=menu]"
  end

  test "DLG-05 [reference] wizard Next is gated by the step; [engineering] Back keeps typed values" do
    open_dialog "Wizard"
    within("dialog#dlg-wizard") do
      assert_selector "[data-wizard-target=next][disabled]"
      fill_in "Account name", with: "Checking"
      assert_no_selector "[data-wizard-target=next][disabled]"
      click_button "Next"
      assert_selector ".wizard__progress", text: "Step 2 of 2"
      assert_selector "[data-wizard-target=finish][disabled]"
      fill_in "Current balance", with: "10"
      assert_no_selector "[data-wizard-target=finish][disabled]"
      click_button "Back"
      assert_equal "Checking", find_field("Account name").value
      click_button "Cancel"
    end
    assert_no_selector "dialog[open]"
  end

  test "DLG-06 [reference] the reference panel does not block the page" do
    click_button "Keyboard shortcuts"
    assert_selector "aside#shortcuts", visible: :visible
    assert_selector "button[aria-expanded=true]", text: "Keyboard shortcuts"
    click_button "View options"
    assert_selector "[role=menu]"
    assert_no_selector "dialog[open]"
    assert_selector "aside#shortcuts", visible: :visible
    click_button "Keyboard shortcuts"
    assert_no_selector "aside#shortcuts", visible: :visible
  end

  test "DLG-06 [engineering] Escape hides the panel, sets aria-expanded false and returns focus to the trigger" do
    click_button "Keyboard shortcuts"
    assert_selector "aside#shortcuts", visible: :visible
    page.send_keys :escape
    assert_no_selector "aside#shortcuts", visible: :visible
    assert_selector "button[aria-expanded=false]", text: "Keyboard shortcuts"
    assert page.evaluate_script("document.activeElement === document.querySelector('[data-panel-target=trigger]')"),
      "focus did not return to the trigger"
    assert page.evaluate_script("document.getElementById('shortcuts').hidden")
  end

  # The preview has no retry handler. "Try again" emits dialog:confirm (what a
  # feature would listen for to re-run its action) and OK emits dialog:dismiss;
  # neither calls anything, so no real action is re-invoked here. That is the whole
  # preview contract, and it is what this test pins. A feature owns the real retry.
  test "DLG-08 [engineering] Try again emits the confirm event, OK emits dismiss, neither sends a request" do
    page.execute_script(<<~JS)
      window.__events = [];
      window.__netCalls = 0;
      const realFetch = window.fetch;
      window.fetch = function(...args) { window.__netCalls += 1; return realFetch.apply(this, args); };
      const err = document.getElementById("dlg-error");
      err.addEventListener("dialog:confirm", () => window.__events.push("confirm"));
      err.addEventListener("dialog:dismiss", (e) => window.__events.push("dismiss:" + e.detail.reason));
    JS
    open_dialog "Error dialog"
    within("dialog#dlg-error") { click_button "Try again" }
    assert_no_selector "dialog[open]"
    assert_equal [ "confirm", "dismiss:confirm" ], page.evaluate_script("window.__events")
    open_dialog "Error dialog"
    within("dialog#dlg-error") { click_button "OK" }
    assert_no_selector "dialog[open]"
    assert_equal [ "confirm", "dismiss:confirm", "dismiss:cancel" ], page.evaluate_script("window.__events")
    assert_equal 0, page.evaluate_script("window.__netCalls")
  end

  test "DLG-04 [engineering] menu list is anchored under its trigger" do
    click_button "View options"
    r = page.evaluate_script("(() => { const t = document.querySelector('[data-menu-target=trigger]').getBoundingClientRect(); const l = document.querySelector('[data-menu-target=list]').getBoundingClientRect(); return { dx: Math.abs(l.left - t.left), dy: l.top - t.bottom }; })()")
    assert_operator r["dx"], :<=, 4, "list left is #{r['dx']}px off the trigger"
    assert_operator r["dy"], :>=, -1
    assert_operator r["dy"], :<=, 16, "list sits #{r['dy']}px below the trigger"
  end

  # Observed current behavior, documented here rather than chosen as policy:
  # Tab closes the menu and does not return focus to the trigger.
  test "DLG-04 [engineering, observed] Tab closes the menu without restoring focus to the trigger" do
    click_button "View options"
    page.send_keys :tab
    assert_no_selector "[role=menu]"
    assert_not page.evaluate_script("document.activeElement === document.querySelector('[data-menu-target=trigger]')"),
      "focus was restored to the trigger"
  end

  test "DLG-05 [engineering, observed] Finish checks only the current step, and clearing step 1 blocks Next again" do
    open_dialog "Wizard"
    within("dialog#dlg-wizard") do
      fill_in "Account name", with: "Checking"
      click_button "Next"
      fill_in "Current balance", with: "10"
      click_button "Back"
      fill_in "Account name", with: ""
      assert_selector "[data-wizard-target=next][disabled]"
      click_button "Cancel"
    end
  end

  test "DLG-01 [engineering] the focus trap skips hidden wizard steps (offsetParent filter)" do
    open_dialog "Wizard"
    fill_in "Account name", with: "x"
    8.times do
      page.send_keys :tab
      assert page.evaluate_script("(() => { const a = document.activeElement; return a.closest('dialog#dlg-wizard') !== null && a.offsetParent !== null; })()"),
        "focus reached a hidden or outside element"
    end
  end
end
