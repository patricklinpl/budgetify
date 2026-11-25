import { Controller } from "@hotwired/stimulus"

// Cmd/Ctrl+Z undoes and Cmd/Ctrl+Y (or Cmd/Ctrl+Shift+Z) redoes by pressing the
// real button, so the server path and the stale check are the same as a click.
// Inert inside text fields (the browser's own text undo wins) and while any
// dialog is open, so Undo can never fire from inside a warning dialog.
export default class extends Controller {
  static targets = [ "undo", "redo" ]

  connect() {
    this.onKey = (event) => this.handle(event)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() { document.removeEventListener("keydown", this.onKey) }

  handle(event) {
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return
    const key = event.key.toLowerCase()
    const redo = key === "y" || (key === "z" && event.shiftKey)
    const undo = key === "z" && !event.shiftKey
    if (!undo && !redo) return
    if (this.blocked(event.target)) return

    const button = redo ? this.redoTarget : this.undoTarget
    if (button.disabled) return
    event.preventDefault()
    button.click()
  }

  blocked(target) {
    if (target && target.closest && target.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']")) return true
    // Closed <dialog role="alertdialog"> elements are in the page, so only an open
    // one counts. The server-rendered reconciled warning section is not a <dialog>.
    if (document.querySelector("dialog[open], section.plan-settings__warning")) return true
    return [ ...document.querySelectorAll("[role='dialog'], [role='alertdialog'], [aria-modal='true']") ]
      .some((el) => el.tagName !== "DIALOG" && !el.hidden && el.getClientRects().length > 0)
  }
}
