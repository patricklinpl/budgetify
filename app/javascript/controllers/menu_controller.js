import { Controller } from "@hotwired/stimulus"

// Dropdown / context menu (DLG-04). Anchored to its trigger, arrow-key
// navigation, Escape and outside click close it, supports toggle items.
export default class extends Controller {
  static targets = [ "trigger", "list" ]

  connect() {
    this.outside = (e) => { if (!this.element.contains(e.target)) this.close(false) }
    document.addEventListener("click", this.outside)
  }

  disconnect() { document.removeEventListener("click", this.outside) }

  get items() { return [ ...this.listTarget.querySelectorAll("[role^=menuitem]") ] }

  toggle() { this.listTarget.hidden ? this.open() : this.close(true) }

  open() {
    this.listTarget.hidden = false
    this.triggerTarget.setAttribute("aria-expanded", "true")
    this.items[0]?.focus()
  }

  close(restore) {
    if (this.listTarget.hidden) return
    this.listTarget.hidden = true
    this.triggerTarget.setAttribute("aria-expanded", "false")
    if (restore) this.triggerTarget.focus()
  }

  keydown(event) {
    const items = this.items
    const i = items.indexOf(document.activeElement)
    if (event.key === "ArrowDown") { event.preventDefault(); items[(i + 1) % items.length]?.focus() }
    else if (event.key === "ArrowUp") { event.preventDefault(); items[(i - 1 + items.length) % items.length]?.focus() }
    else if (event.key === "Home") { event.preventDefault(); items[0]?.focus() }
    else if (event.key === "End") { event.preventDefault(); items[items.length - 1]?.focus() }
    else if (event.key === "Escape") { event.preventDefault(); this.close(true) }
    else if (event.key === "Tab") this.close(false)
  }

  triggerKey(event) {
    if (event.key === "ArrowDown") { event.preventDefault(); this.open() }
  }

  choose(event) {
    const item = event.currentTarget
    if (item.getAttribute("role") === "menuitemcheckbox") {
      item.setAttribute("aria-checked", String(item.getAttribute("aria-checked") !== "true"))
    } else {
      this.close(true)
    }
    this.element.dispatchEvent(new CustomEvent("menu:choose", { bubbles: true, detail: { item: item.dataset.item } }))
  }
  }
