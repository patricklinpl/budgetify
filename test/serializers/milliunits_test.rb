require "test_helper"

class MilliunitsTest < ActiveSupport::TestCase
  test "renders the milliunit, currency and formatted triple" do
    assert_equal(
      { balance: 123450, balance_currency: 123.45, balance_formatted: "$123.45" },
      Milliunits.fields(:balance, 123450)
    )
  end

  test "outflows are negative in every representation" do
    assert_equal(
      { activity: -4000, activity_currency: -4.0, activity_formatted: "-$4.00" },
      Milliunits.fields(:activity, -4000)
    )
  end

  test "renders the plan's currency format" do
    eur = CurrencyFormat.new(
      iso_code: "EUR", example_format: "123.456,78", decimal_digits: 2,
      decimal_separator: ",", symbol_first: false, group_separator: ".",
      currency_symbol: "€", display_symbol: true
    )

    assert_equal 123456.79, Milliunits.to_currency(123456789, eur)
    assert_equal "123.456,79€", Milliunits.format(123456789, eur)
  end

  test "whole units pad the fraction to the format's decimal digits" do
    assert_equal "$123.00", Milliunits.format(123000)
  end

  test "currency format serializes to the YNAB CurrencyFormat schema" do
    assert_equal(
      {
        "iso_code" => "USD", "example_format" => "123,456.78", "decimal_digits" => 2,
        "decimal_separator" => ".", "symbol_first" => true, "group_separator" => ",",
        "currency_symbol" => "$", "display_symbol" => true
      },
      CurrencyFormat.default.as_json
    )
  end
end
