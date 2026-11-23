import { Controller } from "@hotwired/stimulus"
import { evaluateCurrency, formatMilliunits, parseDate } from "controllers/lib/currency_expression"

// Editor field convention (FRM-02, FRM-03, FRM-05, FRM-07):
//   Enter commits, Escape cancels and restores the prior value, leaving the
//   field (blur) commits with the same validation. Invalid input shows an
//   inline error, keeps the typed text, and never writes.
// data-field-kind-value: "currency" | "date" | "text"
export default class extends Controller {
  static targets = [ "input", "error", "status" ]
  static values = { kind: String, committed: String }

  connect() {
    if (!this.hasCommittedValue) this.committedValue = this.inputTarget.value
  }

  keydown(event) {
    if (event.key === "Enter") { event.preventDefault(); this.commit() }
    if (event.key === "Escape") { event.preventDefault(); this.cancel() }
  }

  blur() {
    if (this.inputTarget.value !== this.committedValue) this.commit()
  }

  commit() {
    const text = this.inputTarget.value
    let result
    if (this.kindValue === "currency") {
      const r = evaluateCurrency(text)
      result = r.ok ? { ok: true, display: formatMilliunits(r.milliunits), raw: r.milliunits } : r
    } else if (this.kindValue === "date") {
      const iso = parseDate(text)
      // FRM-07: an invalid typed date reverts to the committed date with a visible cue.
      if (!iso) {
        this.inputTarget.value = this.committedValue
        return this.showError(`"${text.trim()}" is not a valid date. Restored ${this.committedValue}. Use MM/DD/YYYY.`)
      }
      result = { ok: true, display: text.trim(), raw: iso }
    } else {
      result = text.trim() === "" && this.inputTarget.required ? { ok: false, error: "This field is required" } : { ok: true, display: text, raw: text }
    }
    if (!result.ok) return this.showError(result.error)
    this.clearError()
    this.inputTarget.value = result.display
    this.committedValue = result.display
    this.element.dataset.committedRaw = result.raw
    this.say(`Saved ${result.display}`)
    this.element.dispatchEvent(new CustomEvent("field:commit", { bubbles: true, detail: { raw: result.raw } }))
  }

  cancel() {
    this.inputTarget.value = this.committedValue
    this.clearError()
    this.say("Edit cancelled, previous value restored")
    this.element.dispatchEvent(new CustomEvent("field:cancel", { bubbles: true }))
  }

  showError(message) {
    this.element.classList.add("field--invalid")
    this.inputTarget.setAttribute("aria-invalid", "true")
    this.errorTarget.textContent = message
    this.errorTarget.hidden = false
    this.element.dispatchEvent(new CustomEvent("field:invalid", { bubbles: true }))
  }

  clearError() {
    this.element.classList.remove("field--invalid")
    this.inputTarget.removeAttribute("aria-invalid")
    this.errorTarget.textContent = ""
    this.errorTarget.hidden = true
  }

  // Typing again clears a stale error.
  typing() { if (this.element.classList.contains("field--invalid")) this.clearError() }

  say(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }

  // Calendar picker: picking a day fills the typed field in the same format.
  pick(event) {
    const [ y, m, d ] = event.currentTarget.dataset.date.split("-")
    this.inputTarget.value = `${m}/${d}/${y}`
    this.commit()
  }
}
