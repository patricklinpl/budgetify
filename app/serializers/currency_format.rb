# YNAB CurrencyFormat value object (spec: CurrencyFormat schema).
#
# Plans persist their own currency settings (issue #54). A plan without a
# stored format renders with the USD default below. Formatting is display
# only: amounts stay integer milliunits everywhere else.
class CurrencyFormat
  include ActiveModel::Model
  include ActiveModel::Attributes

  DECIMAL_SEPARATORS = [ ".", "," ].freeze
  GROUP_SEPARATORS = [ ".", ",", " ", "'", "" ].freeze
  MAX_DECIMAL_DIGITS = 3 # milliunits carry three decimals

  attribute :iso_code, :string
  attribute :example_format, :string
  attribute :decimal_digits, :integer, default: 2
  attribute :decimal_separator, :string, default: "."
  attribute :symbol_first, :boolean, default: true
  attribute :group_separator, :string, default: ","
  attribute :currency_symbol, :string, default: "$"
  attribute :display_symbol, :boolean, default: true

  # USD, matching YNAB's default currency format.
  def self.default
    new(
      iso_code: "USD",
      example_format: "123,456.78",
      decimal_digits: 2,
      decimal_separator: ".",
      symbol_first: true,
      group_separator: ",",
      currency_symbol: "$",
      display_symbol: true
    )
  end

  # Builds a validated format from request values merged over `base`.
  # Returns [format, errors]; errors is empty when the format is valid.
  def self.build(values, base: default)
    values = values.to_h.stringify_keys
    merged = base.as_json.merge(values.slice(*base.as_json.keys))
    format = new(merged.except("example_format"))
    errors = format.validation_errors(values)
    format.example_format = format.format_number(123_456_780) if errors.empty?
    [ format, errors ]
  end

  def validation_errors(raw = {})
    errors = []
    errors << "iso_code must be three capital letters" unless iso_code.to_s.match?(/\A[A-Z]{3}\z/)
    unless raw.fetch("decimal_digits", 0).is_a?(Integer) && (0..MAX_DECIMAL_DIGITS).cover?(decimal_digits.to_i)
      errors << "decimal_digits must be a whole number from 0 to #{MAX_DECIMAL_DIGITS}"
    end
    errors << "decimal_separator must be . or ," unless DECIMAL_SEPARATORS.include?(decimal_separator)
    errors << "group_separator must be ., a comma, a space, ' or empty" unless GROUP_SEPARATORS.include?(group_separator)
    if group_separator.present? && group_separator == decimal_separator
      errors << "group_separator and decimal_separator must differ"
    end
    errors << "currency_symbol must be 1 to 4 visible characters" unless currency_symbol.to_s.match?(/\A[^[:cntrl:]\s]{1,4}\z/)
    %w[symbol_first display_symbol].each do |key|
      errors << "#{key} must be true or false" if raw.key?(key) && ![ true, false ].include?(raw[key])
    end
    errors
  end

  # Formats milliunits for display, e.g. -300000 -> "-$300.00" or "-300,00$".
  # Rounds half away from zero at the display precision. Display only.
  def format_milliunits(milliunits)
    number = format_number(milliunits.abs)
    number = "#{currency_symbol}#{number}" if display_symbol && symbol_first
    number = "#{number}#{currency_symbol}" if display_symbol && !symbol_first
    milliunits.negative? ? "-#{number}" : number
  end

  def format_number(abs_milliunits)
    digits = decimal_digits.to_i.clamp(0, MAX_DECIMAL_DIGITS)
    scale = 10**(MAX_DECIMAL_DIGITS - digits)
    rounded = (abs_milliunits.abs + scale / 2) / scale
    whole, fraction = rounded.divmod(10**digits)
    grouped = whole.to_s.reverse.scan(/\d{1,3}/).join(group_separator.to_s).reverse
    digits.zero? ? grouped : "#{grouped}#{decimal_separator}#{fraction.to_s.rjust(digits, '0')}"
  end

  def as_json(*)
    {
      "iso_code" => iso_code,
      "example_format" => example_format,
      "decimal_digits" => decimal_digits,
      "decimal_separator" => decimal_separator,
      "symbol_first" => symbol_first,
      "group_separator" => group_separator,
      "currency_symbol" => currency_symbol,
      "display_symbol" => display_symbol
    }
  end
end
