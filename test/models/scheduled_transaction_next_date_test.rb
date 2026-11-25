require "test_helper"

# #61 SCHED-03: next date after a twiceAMonth schedule is entered. The 14 input
# and next dates are the audit's table. Feb 15 -> Feb 28 is also an observed
# persisted vector (SCHED-BOUNDARY-02, [reference T]); the rest are the audit's
# client-helper vectors ([reference C], not persisted-end-to-end verified).
class ScheduledTransactionNextDateTest < ActiveSupport::TestCase
  VECTORS = {
    "2026-12-05" => "2026-12-20", "2026-12-15" => "2026-12-30",
    "2026-12-16" => "2027-01-01", "2026-12-20" => "2027-01-05",
    "2026-12-28" => "2027-01-13", "2026-12-30" => "2027-01-15",
    "2026-12-31" => "2027-01-16", "2027-02-01" => "2027-02-16",
    "2027-02-14" => "2027-02-28", "2027-02-15" => "2027-02-28",
    "2027-02-16" => "2027-03-01", "2027-02-28" => "2027-03-13",
    "2028-02-15" => "2028-02-29", "2028-02-29" => "2028-03-14"
  }.freeze

  VECTORS.each do |from, to|
    test "twiceAMonth #{from} advances to #{to} [reference]" do
      assert_equal Date.parse(to), ScheduledTransaction.next_twice_a_month(Date.parse(from))
    end
  end

  test "twiceAMonth is not a constant 15-day step [reference]" do
    assert_not_equal Date.new(2027, 2, 15) + 15, ScheduledTransaction.next_twice_a_month(Date.new(2027, 2, 15))
    assert_not_equal Date.new(2026, 12, 16) + 15, ScheduledTransaction.next_twice_a_month(Date.new(2026, 12, 16))
  end
end
