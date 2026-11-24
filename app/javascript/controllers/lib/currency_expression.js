// Safe arithmetic for currency inputs (FRM-02). No eval. Returns an object:
// { ok: true, milliunits } or { ok: false, error }. Invalid input is never
// turned into zero.
export const MAX_MILLIUNITS = 1_000_000_000_000

export function evaluateCurrency(text) {
  const src = String(text).replace(/[$\s]/g, "")
  if (src === "") return { ok: false, error: "Enter an amount" }
  if (!/^[0-9.,+\-*/()]+$/.test(src)) return { ok: false, error: "Use numbers and + - * / only" }

  let i = 0
  const fail = () => { throw new Error("Not a valid amount") }
  const peek = () => src[i]

  function number() {
    // Commas are thousands separators only: 1,234.56 is valid, 1,5 and 12,34 are not.
    const m = /^((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)/.exec(src.slice(i))
    if (!m) {
      if (src[i] === ",") throw new Error("Check commas: use 1,234.56 (commas only as thousands separators)")
      if (src[i] === ".") throw new Error("Check the decimal point: use a number like 12.50")
      fail()
    }
    i += m[0].length
    if (src[i] === ",") throw new Error("Check commas: use 1,234.56 (commas only as thousands separators)")
    if (src[i] === ".") throw new Error("Check the decimal point: use one decimal point with digits after it, like 12.50")
    if (/\d/.test(src[i] || "")) throw new Error("Check commas: use 1,234.56 (commas only as thousands separators)")
    return parseFloat(m[0].replace(/,/g, ""))
  }
  function factor() {
    if (peek() === "-") { i++; return -factor() }
    if (peek() === "+") { i++; return factor() }
    if (peek() === "(") {
      i++
      const v = expr()
      if (peek() !== ")") fail()
      i++
      return v
    }
    return number()
  }
  function term() {
    let v = factor()
    while (peek() === "*" || peek() === "/") {
      const op = src[i++]
      const r = factor()
      if (op === "/" && r === 0) throw new Error("Cannot divide by zero")
      v = op === "*" ? v * r : v / r
    }
    return v
  }
  function expr() {
    let v = term()
    while (peek() === "+" || peek() === "-") {
      const op = src[i++]
      const r = term()
      v = op === "+" ? v + r : v - r
    }
    return v
  }

  try {
    const value = expr()
    if (i !== src.length || !Number.isFinite(value)) fail()
    // Precision policy: amounts are whole cents. A result with fractions of a
    // cent is rejected so what is shown is exactly what is stored.
    const cents = Math.round(value * 100)
    if (Math.abs(value * 100 - cents) > 1e-6) throw new Error("Use at most 2 decimal places (whole cents)")
    // Same ceiling as the server (AssignedExpression::LIMIT) so both agree.
    if (Math.abs(cents) * 10 >= MAX_MILLIUNITS) throw new Error("That amount is too large")
    return { ok: true, milliunits: cents * 10 }
  } catch (e) {
    return { ok: false, error: e.message }
  }
}

export function formatMilliunits(milliunits) {
  const sign = milliunits < 0 ? "-" : ""
  const abs = Math.abs(milliunits) / 1000
  return sign + "$" + abs.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

// FRM-07: strict MM/DD/YYYY parse; returns an ISO date string or null.
export function parseDate(text) {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(String(text).trim())
  if (!m) return null
  const [ , mo, d, y ] = m.map(Number)
  const date = new Date(Date.UTC(y, mo - 1, d))
  if (date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 || date.getUTCDate() !== d) return null
  return date.toISOString().slice(0, 10)
}
// end of currency_expression
