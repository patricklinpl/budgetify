import { Controller } from "@hotwired/stimulus"

// Register editor: a "To/From <account>" payee is a transfer or card payment.
// As in the reference, picking one replaces the category: the Category control
// shows the card's Credit Card Payments category or "Category not needed" and
// is disabled, so nothing the user chose is saved or dropped without showing.
// Clearing the payee brings back the category that was selected before.
export default class extends Controller {
  static targets = [ "payee", "category", "replacement", "status" ]
  static values = { labels: Object }

  connect() { this.sync() }

  sync() {
    const key = Object.keys(this.labelsValue).find((name) => name.toLowerCase() === this.payeeTarget.value.trim().toLowerCase())
    const select = this.categoryTarget
    if (key !== undefined) {
      if (!select.disabled) this.previous = select.value
      this.replacementTarget.textContent = this.labelsValue[key]
      this.replacementTarget.hidden = false
      this.replacementTarget.selected = true
      select.disabled = true
      this.statusTarget.textContent = `Category: ${this.labelsValue[key]}`
    } else if (select.disabled) {
      select.disabled = false
      this.replacementTarget.hidden = true
      select.value = this.previous || ""
      this.statusTarget.textContent = ""
    }
  }
}
