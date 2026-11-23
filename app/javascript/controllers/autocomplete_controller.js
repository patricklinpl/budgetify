import { Controller } from "@hotwired/stimulus"

// Suggestion list (FRM-01, FRM-06). Options carry data-hidden="true" for hidden
// payees: they are never offered as suggestions for new entries (rule matching
// is server-side and unaffected). Arrow keys move, Enter picks, Escape closes.
export default class extends Controller {
  static targets = [ "input", "list" ]

  connect() { this.index = -1; this.close() }

  get options() { return [ ...this.listTarget.querySelectorAll("[role=option]") ] }

  filter() {
    const q = this.inputTarget.value.trim().toLowerCase()
    let shown = 0
    this.options.forEach((o) => {
      const match = q !== "" && o.dataset.hidden !== "true" && o.textContent.toLowerCase().includes(q)
      o.hidden = !match
      o.setAttribute("aria-selected", "false")
      if (match) shown++
    })
    this.index = -1
    this.listTarget.hidden = shown === 0
    this.inputTarget.setAttribute("aria-expanded", String(shown > 0))
  }

  keydown(event) {
    const visible = this.options.filter((o) => !o.hidden)
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (visible.length === 0) return
      event.preventDefault()
      this.index = (this.index + (event.key === "ArrowDown" ? 1 : -1) + visible.length) % visible.length
      this.options.forEach((o) => o.setAttribute("aria-selected", "false"))
      visible[this.index].setAttribute("aria-selected", "true")
      this.inputTarget.setAttribute("aria-activedescendant", visible[this.index].id)
    } else if (event.key === "Enter" && this.index >= 0) {
      event.preventDefault()
      this.choose(visible[this.index])
    } else if (event.key === "Escape" && !this.listTarget.hidden) {
      event.preventDefault()
      this.close()
    }
  }

  click(event) {
    const option = event.target.closest("[role=option]")
    if (option) this.choose(option)
  }

  choose(option) {
    this.inputTarget.value = option.textContent.trim()
    this.close()
  }

  close() {
    this.listTarget.hidden = true
    this.index = -1
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
  }
}
