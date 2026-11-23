require "test_helper"

class FormPrimitivesTest < ActionDispatch::IntegrationTest
  test "preview renders each control with its states" do
    get ui_forms_path

    assert_response :success
    assert_select "html[data-theme='light']"
    assert_select "input.field__input[disabled]"
    assert_select ".field--invalid .field__error", /required/
    assert_select "input[data-field-target='input']", minimum: 3
    assert_select "[data-field-kind-value='currency']"
    assert_select "[data-field-kind-value='date']"
    assert_select ".date-picker .date-picker__day", count: 30
    assert_select "input[role='combobox'][aria-controls='payee-list']"
    assert_select "input[type='checkbox']", minimum: 3
    assert_select "input[type='radio'][name='repeat']", count: 2
    %w[primary secondary destructive].each { |k| assert_select "button.btn--#{k}" }
    assert_select "button.btn--primary[disabled]"
    assert_select "button[data-form-target='submit']"
  end

  test "hidden payees are marked so autocomplete can exclude them" do
    get ui_forms_path

    assert_select "li[role='option'][data-hidden='true']", count: 1
    assert_select "li[role='option'][data-hidden='false']", count: 3
  end

  test "dark theme is selectable" do
    get ui_forms_path(theme: "dark")

    assert_select "html[data-theme='dark']"
  end
end
