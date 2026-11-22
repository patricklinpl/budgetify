# YNAB money convention: all amounts are integer milliunits
# ($123.45 is 123450; outflows are negative). Canonical API fields always
# carry the integer milliunit value, with a decimal *_currency companion
# and a display *_formatted string rendered with the plan's currency
# format (spec: CurrencyFormat schema).
#
#   Milliunits.fields(:balance, 123450)
#   # => { balance: 123450, balance_currency: 123.45, balance_formatted: "$123.45" }
module Milliunits
  MILLIUNITS_PER_UNIT = 1000

  module_function

    # Decimal currency value for the *_currency companion field.
    def to_currency(milliunits, currency_format = CurrencyFormat.default)
      decimals = currency_format.decimal_digits || 2
      (milliunits.to_i / MILLIUNITS_PER_UNIT.to_d).round(decimals).to_f
    end

    # Display string for the *_formatted companion field (e.g. "$123.45",
    # "-$4.00", "123.456,79€" depending on the plan's currency format).
    def format(milliunits, currency_format = CurrencyFormat.default)
      decimals = currency_format.decimal_digits || 2
      value = (milliunits.to_i.abs / MILLIUNITS_PER_UNIT.to_d).round(decimals)
      whole, fraction = value.to_d.to_s("F").split(".")
      whole = whole.gsub(/(\d)(?=(\d{3})+(?!\d))/, "\\1#{currency_format.group_separator}")
      fraction = decimals.positive? ? fraction.to_s.ljust(decimals, "0") : nil
      number = [ whole, fraction ].compact.join(currency_format.decimal_separator.to_s)
      if currency_format.display_symbol
        number = currency_format.symbol_first ? "#{currency_format.currency_symbol}#{number}" : "#{number}#{currency_format.currency_symbol}"
      end
      milliunits.to_i.negative? ? "-#{number}" : number
    end

    # The full milliunit + *_currency + *_formatted triple for one field.
    def fields(field, milliunits, currency_format = CurrencyFormat.default)
      {
        field.to_sym => milliunits.to_i,
        "#{field}_currency".to_sym => to_currency(milliunits, currency_format),
        "#{field}_formatted".to_sym => format(milliunits, currency_format)
      }
    end
end
