import { Controller } from "@hotwired/stimulus"

// Submits this form after a field commits cleanly (field:commit), so Enter or
// leaving a valid Assigned field saves it. Invalid text never reaches here:
// the shared field controller keeps it and shows the inline error.
// One request at a time: a second commit while one is in flight is ignored, so
// double Enter or Enter then blur cannot send duplicates. The flag resets when
// the request ends (turbo:submit-end), whether it succeeded or failed.
// If the request fails or is aborted before a response, the save outcome is
// unknown: keep the typed text, say so in the field's alert, and let Enter
// retry. Retrying is safe because Assigned is an absolute amount, not a delta.
export default class extends Controller {
  submit() {
    if (this.sending) return
    this.sending = true
    this.element.requestSubmit()
  }

  end(event) {
    this.sending = false
    const { success, fetchResponse, error } = event.detail || {}
    if (success || (fetchResponse && !error)) return // server answered; its render owns the message
    const err = this.element.querySelector("[data-field-target='error']")
    const status = this.element.querySelector("[data-field-target='status']")
    if (err) {
      err.textContent = "Could not confirm the save. It may or may not have been saved. Your text is kept: press Enter to try again."
      err.hidden = false
    }
    if (status) status.textContent = "Save not confirmed"
  }
}
