import { Controller } from "@hotwired/stimulus"

// Submits this form after a field commits cleanly (field:commit), so Enter or
// leaving a valid Assigned field saves it. Invalid text never reaches here:
// the shared field controller keeps it and shows the inline error. One request
// at a time: a second commit while one is in flight is ignored, so double Enter
// or Enter then blur cannot send duplicates.
export default class extends Controller {
  submit() {
    if (this.sending) return
    this.sending = true
    this.element.requestSubmit()
  }
}
