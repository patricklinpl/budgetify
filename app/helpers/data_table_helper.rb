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
end
