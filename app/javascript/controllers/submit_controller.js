import { Controller } from "@hotwired/stimulus"

// Submits this form after a field commits cleanly (field:commit), so Enter or
// leaving a valid Assigned field saves it. Invalid text never reaches here:
// the shared field controller keeps it and shows the inline error.
export default class extends Controller {
  submit() { this.element.requestSubmit() }
}
