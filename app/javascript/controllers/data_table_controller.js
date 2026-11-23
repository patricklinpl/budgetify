import { Controller } from "@hotwired/stimulus"

// Presentation behavior for the table primitives (#69). No data logic:
// group collapse (TAB-02), progress bars on/off (TAB-04), optional columns
// (TAB-05), row selection state (TAB-01) and the inline editor host (TAB-06).
const BARS_KEY = "budgetify.tableBars"

export default class extends Controller {
  static targets = [ "table" ]

  connect() {
    const stored = window.localStorage.getItem(BARS_KEY)
    if (stored) document.documentElement.setAttribute("data-table-bars", stored)
  }

  // TAB-02: collapse hides member rows only; the group row and its totals stay.
  toggleGroup(event) {
    const button = event.currentTarget
    const expanded = button.getAttribute("aria-expanded") !== "true"
    button.setAttribute("aria-expanded", String(expanded))
    const id = button.closest("tr").dataset.groupId
    this.element.querySelectorAll(`[data-group="${id}"]`).forEach((row) => { row.hidden = !expanded })
  }

  // TAB-04: document-level toggle, amounts untouched.
  toggleBars(event) {
    const value = event.currentTarget.checked ? "on" : "off"
    document.documentElement.setAttribute("data-table-bars", value)
    window.localStorage.setItem(BARS_KEY, value)
  }

  // TAB-05: hide or show optional columns without touching the data.
  toggleColumn(event) {
    const { column } = event.currentTarget.dataset
    const hidden = new Set((this.tableTarget.dataset.hide || "").split(" ").filter(Boolean))
    if (event.currentTarget.checked) hidden.delete(column); else hidden.add(column)
    this.tableTarget.dataset.hide = [ ...hidden ].join(" ")
  }

  // TAB-01: selected state mirrors the checkbox.
  select(event) {
    event.currentTarget.closest("tr").setAttribute("aria-selected", String(event.currentTarget.checked))
  }

  // TAB-06: expand a row into its editor host and move focus into it.
  edit(event) {
    const row = event.currentTarget.closest("tr")
    const editor = document.getElementById(row.dataset.editorId)
    if (!editor) return
    row.classList.add("data-table__row--editing")
    editor.hidden = false
    const focusable = editor.querySelector("input, select, textarea, button")
    if (focusable) focusable.focus()
    editor.dataset.returnTo = event.currentTarget.id
  }

  cancel(event) {
    const editor = event.currentTarget.closest("tr")
    editor.hidden = true
    editor.previousElementSibling.classList.remove("data-table__row--editing")
    const trigger = document.getElementById(editor.dataset.returnTo)
    if (trigger) trigger.focus()
  }

  keydown(event) {
    if (event.key === "Escape") {
      const cancel = event.currentTarget.querySelector("[data-action~='data-table#cancel']")
      if (cancel) cancel.click()
    }
  }
}
