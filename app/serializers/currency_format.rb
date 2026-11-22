# YNAB CurrencyFormat value object (spec: CurrencyFormat schema).
#
# Plans will persist their own date/currency settings (issue #27); until
# then every plan renders with the USD default below.
class CurrencyFormat
  include ActiveModel::Model
  include ActiveModel::Attributes

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
