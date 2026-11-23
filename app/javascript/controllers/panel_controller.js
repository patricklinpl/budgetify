import { Controller } from "@hotwired/stimulus"

// Non-modal overlay for reference panels (DLG-06). It does not block the
// screen behind it: no backdrop, nothing inert, focus is not trapped.
export default class extends Controller {
  static targets = [ "panel", "trigger" ]

  toggle() { this.panelTarget.hidden ? this.open() : this.close() }

  open() {
    this.panelTarget.hidden = false
    this.triggerTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.panelTarget.hidden = true
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.triggerTarget.focus()
  }

  keydown(event) {
    if (event.key === "Escape") { event.preventDefault(); this.close() }
  }
}
