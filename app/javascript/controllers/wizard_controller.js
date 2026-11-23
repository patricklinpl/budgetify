import { Controller } from "@hotwired/stimulus"

// Multi-step flow (DLG-05). Next stays disabled until every required field on
// the current step is valid; Back never loses entered values.
export default class extends Controller {
  static targets = [ "step", "next", "back", "finish", "progress" ]

  connect() { this.index = 0; this.render() }

  get required() { return [ ...this.stepTargets[this.index].querySelectorAll("[required]") ] }

  validate() {
    const ok = this.required.every((el) => el.value.trim() !== "")
    const last = this.index === this.stepTargets.length - 1
    this.nextTarget.disabled = !ok
    this.finishTarget.disabled = !ok
    this.nextTarget.hidden = last
    this.finishTarget.hidden = !last
  }

  next() { if (!this.nextTarget.disabled) { this.index++; this.render() } }
  back() { if (this.index > 0) { this.index--; this.render() } }

  render() {
    this.stepTargets.forEach((s, i) => { s.hidden = i !== this.index })
    this.backTarget.hidden = this.index === 0
    this.progressTarget.textContent = `Step ${this.index + 1} of ${this.stepTargets.length}`
    this.validate()
    this.stepTargets[this.index].querySelector("input, select")?.focus()
  }
}
