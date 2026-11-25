import { Controller } from "@hotwired/stimulus"

// Reconciled-row editors ask first only when a field the reference warns on
// has changed (reference checks: amount edits and a split parent's total
// warn; memo-only edits and moving amounts between split children at the same
// total do not). The server makes the same decision, so this only decides
// whether to open the dialog or submit straight away.
//   data-reconcile-guard-initial-value: { "<field name>": "<stored value>" }
// Save buttons carry data-reconcile-guard-save and run check before dialog#open.
export default class extends Controller {
  static values = { initial: Object }

  check(event) {
    if (this.changed()) return
    event.preventDefault()
    event.stopImmediatePropagation()
    this.element.requestSubmit()
  }

  // Enter in a text field means Save: it must follow the same path as the
  // Save button, never reach a confirm button inside the closed dialog.
  enter(event) {
    if (event.key !== "Enter" || event.isComposing) return
    const target = event.target
    if (target.tagName !== "INPUT" || [ "button", "submit", "checkbox", "radio" ].includes(target.type)) return
    event.preventDefault()
    const save = this.element.querySelector("[data-reconcile-guard-save]")
    if (save && !save.disabled) save.click()
  }

  changed() {
    return Object.entries(this.initialValue).some(([ name, stored ]) => {
      const field = this.element.querySelector(`[name="${name}"]`)
      return field ? this.normalize(field.value) !== this.normalize(stored) : false
    })
  }

  normalize(value) {
    const text = String(value ?? "").trim()
    const plain = text.replace(/,/g, "")
    return /^\d*\.?\d+$|^\d+\.$/.test(plain) ? String(Number(plain)) : text
  }
}
