require "test_helper"

class DialogPrimitivesTest < ActionDispatch::IntegrationTest
  test "preview renders every dialog primitive with its contract" do
    get ui_dialogs_path

    assert_response :success
    assert_select "html[data-theme='light']"
    # DLG-01 labelled modal dialogs with explicit backdrop policy
    assert_select "dialog.dialog[aria-labelledby]", minimum: 5
    assert_select "dialog[data-dialog-backdrop='dismiss']", count: 1
    assert_select "dialog[data-dialog-backdrop='block']", minimum: 4
    assert_select "dialog.dialog--warning[role='alertdialog']"
    assert_select "dialog[data-action*='dialog#trap']", minimum: 5
    # DLG-02 consequence confirm: facts shown, confirm disabled until a choice
    assert_select "dialog.dialog--destructive .dialog__facts li", count: 2
    assert_select "dialog.dialog--destructive select[required]"
    assert_select "dialog.dialog--destructive button[data-dialog-confirm][disabled]"
    # DLG-03 inline confirm
    assert_select "[data-controller='inline-confirm'] [data-inline-confirm-target='confirm'][hidden]"
    # DLG-04 menu with toggles and a destructive entry
    assert_select "[role='menu'] [role='menuitemcheckbox']", count: 2
    assert_select ".menu__item--destructive"
    assert_select "button[aria-haspopup='menu'][aria-expanded='false']"
    # DLG-05 wizard: two steps, Next present
    assert_select "[data-wizard-target='step']", count: 2
    assert_select "[data-wizard-target='next']"
    # DLG-06 non-modal overlay is an aside, not a dialog
    assert_select "aside.panel[role='complementary'][hidden]"
    # DLG-07 every dialog states what survives dismissal
    assert_select "dialog .dialog__survives", count: 6
    # DLG-08 error dialog with retry
    assert_select "dialog.dialog--error[role='alertdialog'] [data-retry]"
  end

  test "dark theme is selectable" do
    get ui_dialogs_path(theme: "dark")

    assert_select "html[data-theme='dark']"
  end
end
