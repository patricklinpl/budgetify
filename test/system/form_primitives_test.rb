require "application_system_test_case"

# Runs the real Stimulus controllers in a browser against the /ui/forms preview.
class FormPrimitivesSystemTest < ApplicationSystemTestCase
  setup { visit ui_forms_path }

  def commit(label, text)
    field = find_field(label)
    field.set(text)
    field.send_keys(:enter)
  end

  test "currency expressions commit as whole cents" do
    commit "Assigned", "10+5*2"

    assert_field "Assigned", with: "$20.00"
    commit "Assigned", "$1,234.56"
    assert_field "Assigned", with: "$1,234.56"
  end

  test "sub-cent results are rejected so display and storage agree" do
    commit "Assigned", "0.004"

    assert_text "Use at most 2 decimal places"
    assert_field "Assigned", with: "0.004"
    commit "Assigned", "10/3"
    assert_text "Use at most 2 decimal places"
  end

  test "ambiguous or malformed comma input is rejected and kept" do
    [ "1,5", "12,34", "1,2345" ].each do |text|
      commit "Assigned", text
      assert_text "Check commas"
      assert_field "Assigned", with: text
    end
  end

  test "invalid expressions keep the typed text with an error" do
    commit "Assigned", "abc"

    assert_text "Use numbers and + - * / only"
    assert_field "Assigned", with: "abc"
  end

  test "an invalid typed date reverts to the committed date with a visible cue" do
    commit "Date", "2/30/2026"

    assert_field "Date", with: "11/23/2026"
    assert_text "Restored 11/23/2026"
    assert_selector "#date-err", text: "not a valid date"
    assert_equal "date-err", find_field("Date")["aria-describedby"]
  end

  test "the calendar picker and typed entry agree and day buttons are fully labelled" do
    find("button[aria-label='November 5, 2026']").click

    assert_field "Date", with: "11/05/2026"
  end

  test "escape restores the prior value" do
    field = find_field("Assigned")
    field.set("999")
    field.send_keys(:escape)

    assert_field "Assigned", with: "$100.00"
  end
end
