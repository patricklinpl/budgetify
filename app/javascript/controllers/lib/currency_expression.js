// Safe arithmetic for currency inputs (FRM-02). No eval. Returns an object:
// { ok: true, milliunits } or { ok: false, error }. Invalid input is never
// turned into zero.
export function evaluateCurrency(text) {
  const src = String(text).replace(/[$,\s]/g, "")
  if (src === "") return { ok: false, error: "Enter an amount" }
  if (!/^[0-9.+\-*/()]+$/.test(src)) return { ok: false, error: "Use numbers and + - * / only" }

  let i = 0
  const fail = () => { throw new Error("Not a valid amount") }
  const peek = () => src[i]

  function number() {
    const m = /^(\d+\.?\d*|\.\d+)/.exec(src.slice(i))
    if (!m) fail()
    i += m[0].length
    return parseFloat(m[0])
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
    return { ok: true, milliunits: Math.round(value * 1000) }
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
