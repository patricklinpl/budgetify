require "test_helper"

class DataTableTest < ActionDispatch::IntegrationTest
  test "preview page renders every table primitive without sign in" do
    get ui_tables_path

    assert_response :success
    assert_select "html[data-theme='light']"
    # TAB-01 base table, selection, money column, empty cell
    assert_select "table.data-table", count: 2
    assert_select ".data-table__row--selected input[type='checkbox'][checked]", minimum: 1
    assert_select "tr[aria-selected]", count: 0
    assert_select ".data-table__money", minimum: 1
    assert_select ".data-table__cell--empty", minimum: 1
    # TAB-02 group rows with chevron
    assert_select "tr.data-table__group .data-table__chevron[aria-expanded='true']", count: 2
    # TAB-03 pills with a text label for each state
    %w[positive underfunded negative zero].each do |kind|
      assert_select ".status-pill--#{kind} .data-table__sr"
    end
    # TAB-04 bar rows
    assert_select ".data-table__bar-row", count: 2
    assert_select "input[data-action='data-table#toggleBars']"
    # TAB-05 register columns, sortable date, hide/show checkboxes, scheduled row
    assert_select "th[aria-sort='descending'] .data-table__sort", "Date"
    assert_select "button[aria-sort]", count: 0
    assert_select "button.data-table__edit-trigger[aria-controls='editor-1'][aria-expanded='false']"
    assert_select "[role='img'][aria-label='Flagged']"
    assert_select "[role='img'][aria-label='Has attachment']"
    assert_select "td[aria-label]", count: 0
    assert_select ".data-table__col--flag", minimum: 1
    assert_select ".data-table__col--image", minimum: 1
    assert_select "input[data-column='flag']"
    assert_select "input[data-column='image']"
    assert_select ".data-table__row--scheduled"
    assert_select ".data-table__row--split .data-table__category", "Split (Multiple Categories)"
    assert_select ".data-table__row--transfer"
    # TAB-06 editor host
    assert_select "tr.data-table__editor[hidden]#editor-1"
    # TAB-07 empty states
    assert_select ".data-table-empty", count: 2
    assert_select ".data-table-empty--filtered"
  end

  test "dark theme is selectable on the preview" do
    get ui_tables_path(theme: "dark")

    assert_response :success
    assert_select "html[data-theme='dark']"
  end

  test "pill helper pairs a label with the amount" do
    html = ApplicationController.helpers.status_pill(:negative, -30_000)

    assert_includes html, "Overspent"
    assert_includes html, "-$30.00"
    assert_includes html, "status-pill--negative"
  end
end
