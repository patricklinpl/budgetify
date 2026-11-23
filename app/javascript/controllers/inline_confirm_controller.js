import { Controller } from "@hotwired/stimulus"

// Row-level destructive confirmation shown where the action was taken (DLG-03).
// Cancel restores the row's normal actions and leaves the data untouched.
export default class extends Controller {
  static targets = [ "actions", "confirm", "ask" ]

  ask() {
    this.actionsTarget.hidden = true
    this.confirmTarget.hidden = false
    this.confirmTarget.querySelector("[data-cancel]").focus()
  }

  cancel() {
    this.confirmTarget.hidden = true
    this.actionsTarget.hidden = false
    this.askTarget.focus()
  }

  confirm() {
    this.element.dispatchEvent(new CustomEvent("inline-confirm:confirm", { bubbles: true }))
    this.element.classList.add("inline-confirm--done")
    this.confirmTarget.hidden = true
  }
}
