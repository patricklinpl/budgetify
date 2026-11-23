import { Controller } from "@hotwired/stimulus"

// Moves keyboard focus to this element when it appears, so a failed submit
// lands on the error instead of the page body.
export default class extends Controller {
  connect() { this.element.focus() }
}
