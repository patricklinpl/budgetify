import { Controller } from "@hotwired/stimulus"

const sessionTokenKey = "budgetify.session_token"

export default class extends Controller {
  static targets = ["email", "error", "form", "password", "passwordToggle", "submit"]

  connect() {
    this.restoreSession()
  }

  async submit(event) {
    event.preventDefault()
    this.errorTarget.hidden = true
    this.submitTarget.disabled = true
    this.submitTarget.textContent = "Signing in…"

    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({ email: this.emailTarget.value, password: this.passwordTarget.value })
      })
      const payload = await response.json()

      if (!response.ok) {
        const message = response.status === 401
          ? "We weren't able to log you in. Please check that your email and password are correct."
          : payload.error?.message || "Unable to sign in. Please try again."
        this.showError(message)
        return
      }

      const catalog = await this.syncCatalogData(payload.session_token)
      sessionStorage.setItem(sessionTokenKey, payload.session_token)
      sessionStorage.setItem("budgetify.catalog", JSON.stringify(catalog))
      window.location.assign("/")
    } catch (error) {
      const message = error instanceof Error && error.message.startsWith("Unable to sync")
        ? error.message
        : "Unable to connect. Check your connection and try again."
      this.showError(message)
    } finally {
      this.submitTarget.disabled = false
      this.submitTarget.textContent = "Log in"
    }
  }

  async syncCatalogData(sessionToken) {
    const response = await fetch("/api/v1/catalog", {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${sessionToken}`,
        "Accept": "application/json"
      }
    })
    if (!response.ok) throw new Error("Unable to sync your budgets. Please try again.")
    return response.json()
  }

  togglePassword() {
    const showingPassword = this.passwordTarget.type === "text"
    this.passwordTarget.type = showingPassword ? "password" : "text"
    this.passwordToggleTarget.textContent = showingPassword ? "Show" : "Hide"
    this.passwordToggleTarget.setAttribute("aria-pressed", String(!showingPassword))
  }


  async restoreSession() {
    const token = sessionStorage.getItem(sessionTokenKey)
    if (!token) return

    try {
      const response = await fetch("/v1/user", {
        headers: { "Authorization": `Bearer ${token}` }
      })
      if (!response.ok) {
        sessionStorage.removeItem(sessionTokenKey)
        sessionStorage.removeItem("budgetify.catalog")
        return
      }

      window.location.assign("/")
    } catch {
      this.showError("Unable to verify your session. Check your connection and try again.")
    }
  }


  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.hidden = false
  }

}
