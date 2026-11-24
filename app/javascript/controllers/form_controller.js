import { Controller } from "@hotwired/stimulus"

// FRM-05: submit stays disabled while any required field is empty or invalid.
export default class extends Controller {
  static targets = [ "submit" ]

  connect() { this.update() }

  update() {
    const required = [ ...this.element.querySelectorAll("[required]") ]
    const missing = required.some((el) => el.value.trim() === "")
    const invalid = this.element.querySelector(".field--invalid:not([data-static])") !== null
    this.submitTargets.forEach((button) => { button.disabled = missing || invalid })
  }
}
