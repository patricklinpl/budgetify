module DataTableHelper
  PILL_LABELS = {
    positive: "Funded",
    underfunded: "Underfunded",
    negative: "Overspent",
    zero: "Zero"
  }.freeze

  # Amounts are milliunits. Display format is a placeholder until plan currency
  # settings land (#54 PLAN-03).
  def data_table_money(milliunits)
    number_to_currency(milliunits / 1000.0)
  end

  # TAB-03: status pill. The glyph comes from the token-driven ::before and the
  # label is available to assistive tech, so meaning does not rely on color.
  def status_pill(kind, milliunits, text: nil)
    kind = kind.to_sym
    tag.span(class: "status-pill status-pill--#{kind}") do
      safe_join([ tag.span(PILL_LABELS.fetch(kind), class: "data-table__sr"), text || data_table_money(milliunits) ])
    end
  end

  # Plan grid: Assigned this month against the plan's monthly target amount, only
  # for the built monthly target (MonthlyTarget.monthly?). It states two existing
  # facts and makes no claim about funding, carryover or the target mode. The
  # meter value is clamped for display; assigned is the actual amount.
  def target_need(category, assigned, format)
    return unless MonthlyTarget.monthly?(category)

    target = category.goal_target.to_i
    remaining = [ target - assigned.to_i, 0 ].max
    { target: target, shown: assigned.to_i.clamp(0, target), remaining: remaining,
      more: (safe_join([ grid_money(format, remaining), " more needed this month" ]) if remaining.positive?),
      text: safe_join([ grid_money(format, assigned.to_i), " assigned of ", grid_money(format, target), " monthly target" ]) }
  end

  # Budget grid amount in the plan's currency format. When the stored value is
  # finer than the display digits (possible through the API), the exact value is
  # printed next to it so rounding never hides money.
  def grid_money(format, milliunits)
    text = format.format_milliunits(milliunits)
    scale = 10**(3 - format.decimal_digits.to_i.clamp(0, 3))
    return text if (milliunits % scale).zero?

    sign = milliunits.negative? ? "-" : ""
    whole, fraction = milliunits.abs.divmod(1000)
    exact = "#{sign}#{whole}.#{fraction.to_s.rjust(3, '0')}"
    safe_join([ text, tag.span("exact #{exact}", class: "budget-grid__exact") ], " ")
  end

  # Plain-text amount for confirmations: the plan-format text, plus the exact
  # value when it is finer than the display digits, so the amount a confirm
  # button commits is never only shown rounded.
  def money_with_exact(format, milliunits)
    text = format.format_milliunits(milliunits)
    scale = 10**(3 - format.decimal_digits.to_i.clamp(0, 3))
    return text if (milliunits % scale).zero?

    sign = milliunits.negative? ? "-" : ""
    whole, fraction = milliunits.abs.divmod(1000)
    "#{text} (exact #{sign}#{whole}.#{fraction.to_s.rjust(3, '0')})"
  end
end
