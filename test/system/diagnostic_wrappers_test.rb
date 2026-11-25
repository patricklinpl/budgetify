require "application_system_test_case"

# Regression for the diagnostic wrappers in ApplicationSystemTestCase. The
# original exception class, message and backtrace must survive; the diagnostics
# are appended, and an unrelated error passes through untouched. Capybara 3.40
# defines Capybara::ExpectationNotMet (there is no Capybara::ExpectationNotFound),
# so the wrappers rescue that constant. No browser page is visited.
class DiagnosticWrappersTest < ApplicationSystemTestCase
  WRAPPERS = {
    input: ->(test, &block) { test.with_input_diagnostics("Save", &block) },
    shell: ->(test, &block) { test.with_shell_diagnostics(&block) }
  }.freeze

  def raised_through(kind, error)
    WRAPPERS.fetch(kind).call(self) { raise error }
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  [ :input, :shell ].each do |kind|
    test "#{kind} wrapper keeps a Minitest assertion's class, message and backtrace" do
      original = Minitest::Assertion.new("boom")
      original.set_backtrace([ "test/system/some_test.rb:25:in 'x'" ])
      raised = raised_through(kind, original)
      assert_instance_of Minitest::Assertion, raised
      assert_match(/\Aboom\n/, raised.message)
      assert_equal [ "test/system/some_test.rb:25:in 'x'" ], raised.backtrace
    end

    test "#{kind} wrapper handles Capybara::ExpectationNotMet and keeps its backtrace" do
      original = Capybara::ExpectationNotMet.new("not met")
      original.set_backtrace([ "test/system/other_test.rb:7:in 'y'" ])
      raised = raised_through(kind, original)
      assert_instance_of Capybara::ExpectationNotMet, raised
      assert_match(/\Anot met\n/, raised.message)
      assert_equal [ "test/system/other_test.rb:7:in 'y'" ], raised.backtrace
    end

    test "#{kind} wrapper leaves an unrelated error unchanged" do
      original = RuntimeError.new("plain")
      raised = raised_through(kind, original)
      assert_same original, raised
      assert_equal "plain", raised.message
    end
  end

  test "input wrapper appends the diagnostics and survives a dead page" do
    raised = raised_through(:input, Minitest::Assertion.new("boom"))
    assert_match(/Input diagnostics: /, raised.message)
    assert_match(/"stimulus":/, raised.message)
  end
end
