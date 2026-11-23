import { Controller } from "@hotwired/stimulus"

// Sidebar collapse to an icon rail (LAY-03, LAY-07). State persists in
// localStorage so it survives reloads and Turbo navigation. Below the
// breakpoint the rail is the default when no choice has been stored.
const KEY = "budgetify.sidebarCollapsed"
const SMALL_QUERY = "(max-width: 900px)"
// Phones: always the rail; the stored desktop choice is ignored, not changed.
const PHONE_QUERY = "(max-width: 600px)"

export default class extends Controller {
  static targets = [ "toggle" ]
  static classes = [ "collapsed" ]

  connect() {
    this.phone = window.matchMedia(PHONE_QUERY)
    this.onPhoneChange = () => this.restore()
    this.phone.addEventListener("change", this.onPhoneChange)
    this.restore()
  }

  disconnect() {
    this.phone.removeEventListener("change", this.onPhoneChange)
  }

  restore() {
    if (this.phone.matches) return this.apply(true)
    const stored = window.localStorage.getItem(KEY)
    this.apply(stored === null ? window.matchMedia(SMALL_QUERY).matches : stored === "true")
  }

  toggle() {
    if (this.phone.matches) return
    const collapsed = !this.element.classList.contains(this.collapsedClass)
    window.localStorage.setItem(KEY, String(collapsed))
    this.apply(collapsed)
  }

  apply(collapsed) {
    this.element.classList.toggle(this.collapsedClass, collapsed)
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
      this.toggleTarget.setAttribute("aria-label", collapsed ? "Expand sidebar" : "Collapse sidebar")
    }
  }
}
