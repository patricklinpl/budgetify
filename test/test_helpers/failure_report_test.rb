require "test_helper"
require "tmpdir"
require_relative "failure_report"

# [engineering] The failure report's formatting. No browser. Synthetic data only.
class FailureReportTest < ActiveSupport::TestCase
  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "[engineering] the element is read from a Capybara message and bounded" do
    message = %(expected to find css ".app-shell-phone-accounts__link" 2 times but there were 0 matching)
    assert_equal "css .app-shell-phone-accounts__link", FailureReport.element_from(message)
    assert_equal %(link Cancel), FailureReport.element_from(%(Unable to find link "Cancel"))
    assert_equal "not named in the error", FailureReport.element_from("Node with given id does not belong to the document")
    assert_operator FailureReport.element_from(%(Unable to find css "#{'a' * 500}")).size, :<=, 160
  end

  test "[engineering] the step is the first test-file frame with its source line" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test/system"))
      File.write(File.join(root, "test/system/x_test.rb"), "a = 1\nassert_selector '.x', count: 2\n")
      frames = [ "/gems/capybara/lib/a.rb:10:in 'x'", "#{root}/test/system/x_test.rb:2:in 'block in <class:X>'" ]
      assert_equal "test/system/x_test.rb:2 assert_selector '.x', count: 2", FailureReport.step_from(frames, root)
    end
    assert_equal "no test frame in the backtrace", FailureReport.step_from([ "/gems/a.rb:1" ])
  end

  test "[engineering] the summary carries test, position, seed, versions, step, error and element" do
    error = Capybara::ExpectationNotMet.new(%(expected to find css ".l" 2 times\nsecond line))
    summary = FailureReport.summary(test_id: "T#test_a", position: 9, seed: 8005,
                                    versions: { chrome: "158.0.8127.36", chromedriver: "158.0.8127.36" },
                                    error: error, backtrace: [ "x" ])
    assert_equal({ test: "T#test_a", position: 9, seed: 8005, chrome: "158.0.8127.36", chromedriver: "158.0.8127.36",
                   step: "no test frame in the backtrace", error_class: "Capybara::ExpectationNotMet",
                   error: %(expected to find css ".l" 2 times\n).chomp, element: "css .l" }, summary)
    assert_includes FailureReport.summary_lines(summary), "FAILURE_SUMMARY position=9"
  end

  test "[engineering] clean keeps printable ASCII only" do
    assert_equal "a?b", FailureReport.clean("a\u0007b", 10)
    assert_equal "abc", FailureReport.clean("abcdef", 3)
  end

  test "[engineering] everything is off without DIAG_ARTIFACT_DIR" do
    with_env("DIAG_ARTIFACT_DIR" => nil, "DIAG_PASS_CONTROL" => "1", "DIAG_INPUT_STATE" => "1", "DIAG_CHROME_LOG" => "1") do
      assert_not FailureReport.enabled?
      assert_not FailureReport.pass_control?
      assert_not FailureReport.input_state?
      assert_empty FailureReport.chrome_args
    end
  end

  test "[engineering] with the directory set the Chrome log goes inside it and the record is written there" do
    Dir.mktmpdir do |tmp|
      with_env("DIAG_ARTIFACT_DIR" => tmp, "DIAG_CHROME_LOG" => "1") do
        assert_includes FailureReport.chrome_args, "--log-file=#{tmp}/chrome.log"
        path = FailureReport.write(3, "A#test_b c", { ok: true })
        assert_equal File.join(tmp, "failures", "003-A_test_b_c.json"), path
        assert_equal({ "ok" => true }, JSON.parse(File.read(path)))
      end
    end
  end
end
