import { Controller } from "@hotwired/stimulus"

// Modal dialogs on the native <dialog> element (DLG-01, DLG-07, DLG-08).
// showModal() makes everything outside inert, so focus is trapped; Escape
// closes only the top-most dialog, so cancelling a warning never cancels the
// editor beneath it. Backdrop policy is explicit per dialog:
//   data-dialog-backdrop="dismiss" closes on backdrop click, "block" ignores it.
// Dismissal never runs a side effect: it emits dialog:dismiss and restores focus.
export default class extends Controller {
  static targets = [ "confirm" ]

  open(event) {
    const dialog = document.getElementById(event.currentTarget.dataset.dialogId)
    if (!dialog) return
    dialog.returnFocusTo = event.currentTarget
    dialog.showModal()
    const first = dialog.querySelector("[autofocus], input, select, textarea, button:not([data-dialog-close])")
    if (first) first.focus()
  }

  // Cancel or Close buttons: no side effects.
  dismiss(event) {
    this.closeDialog(event.currentTarget.closest("dialog"), "cancel")
  }

  // Primary action: emits the choice; features own what happens next.
  confirm(event) {
    const dialog = event.currentTarget.closest("dialog")
    dialog.dispatchEvent(new CustomEvent("dialog:confirm", { bubbles: true, detail: { action: event.currentTarget.dataset.action } }))
    this.closeDialog(dialog, "confirm")
  }

  // Native Escape: the browser closes the dialog; we only report and restore focus.
  cancelEvent(event) {
    event.preventDefault()
    this.closeDialog(event.currentTarget, "escape")
  }

  backdrop(event) {
    const dialog = event.currentTarget
    if (event.target !== dialog) return
    if (dialog.dataset.dialogBackdrop === "dismiss") this.closeDialog(dialog, "backdrop")
  }

  closeDialog(dialog, reason) {
    if (!dialog.open) return
    dialog.close()
    dialog.dispatchEvent(new CustomEvent("dialog:dismiss", { bubbles: true, detail: { reason } }))
    this.status(`${dialog.dataset.dialogName || "Dialog"} closed (${reason})`)
    if (dialog.returnFocusTo) dialog.returnFocusTo.focus()
  }

  // Keep Tab and Shift+Tab cycling inside the dialog (explicit trap on top of
  // the inert background, so focus never lands on the browser chrome).
  trap(event) {
    if (event.key !== "Tab") return
    const dialog = event.currentTarget
    const focusable = [ ...dialog.querySelectorAll("a[href], button:not([disabled]):not([hidden]), input:not([disabled]), select:not([disabled]), textarea:not([disabled])") ]
      .filter((el) => el.offsetParent !== null)
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
  }

  // DLG-02: confirm stays disabled until every required choice is made.
  gate(event) {
    const dialog = event.currentTarget.closest("dialog")
    const ok = [ ...dialog.querySelectorAll("[required]") ].every((el) => el.value.trim() !== "")
    const button = dialog.querySelector("[data-dialog-confirm]")
    if (button) button.disabled = !ok
  }

  status(text) {
    const live = document.getElementById("dialog-status")
    if (live) live.textContent = text
  }
}
