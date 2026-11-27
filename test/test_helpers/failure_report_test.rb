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
                   error: %(expected to find css ".l" 2 times\n).chomp, element: "css .l",
                   test_defined_at: "unknown", backtrace: "1 frames, last: x" }, summary)
    assert_includes FailureReport.summary_lines(summary), "FAILURE_SUMMARY position=9"
  end

  test "[engineering] without a test frame the report still says where the test is defined and where the trace ends" do
    frames = [ "/gems/selenium/response.rb:63:in 'add_cause'", "/home/r/vendor/bundle/ruby/3.4.0/gems/capybara-3.40.0/lib/capybara/result.rb:32:in 'block in initialize'" ]
    assert_equal "2 frames, last: gems/capybara-3.40.0/lib/capybara/result.rb:32:in 'block in initialize'", FailureReport.trace_tail(frames)
    assert_equal "0 frames, last: ", FailureReport.trace_tail(nil)
    assert_equal "test/system/x_test.rb:74", FailureReport.definition_from([ "/home/r/work/b/test/system/x_test.rb", 74 ])
    assert_equal "unknown", FailureReport.definition_from(nil)
    summary = FailureReport.summary(test_id: "T#a", position: 1, seed: 1, versions: { chrome: "1", chromedriver: "1" },
                                    error: RuntimeError.new("boom"), backtrace: frames, location: [ "/home/r/work/b/test/system/x_test.rb", 74 ])
    assert_equal "no test frame in the backtrace", summary[:step]
    assert_equal "test/system/x_test.rb:74", summary[:test_defined_at]
  end

  test "[engineering] failure_lines prints focus, active element, keydown count, targets and the send_keys offsets" do
    capture = { "focus" => false, "active" => "input#q",
                "inputLog" => [ "10ms keydown a input#q", "11ms keyup a input#q", "12ms keydown b input#q", "13ms click x" ] }
    state = { targets: [ { type: "page", id: "ABCD1234", attached: true }, { type: "service_worker", id: "EF567890", attached: false } ] }
    lines = FailureReport.failure_lines(capture, state, [ 120, 480 ])
    assert_equal "FAILURE_PAGE focus=false active=input#q keydown_count=2 targets=page:ABCD1234:true,service_worker:EF567890:false", lines.first
    assert_equal "FAILURE_KEYS send_keys_at_ms=120,480", lines.last
  end

  test "[engineering] failure_lines survives a missing capture and a browser error" do
    lines = FailureReport.failure_lines({ "unavailable" => "Timeout::Error" }, { error: "X" }, nil)
    assert_equal "FAILURE_PAGE focus= active= keydown_count=0 targets=", lines.first
    assert_equal "FAILURE_KEYS send_keys_at_ms=", lines.last
  end

  test "[engineering] the key stamp records an offset and never calls the driver" do
    FailureReport.reset_inputs(Object.new)
    FailureReport.stamp_keys
    FailureReport.stamp_keys
    assert_equal 2, FailureReport.keys.size
    FailureReport.reset_inputs(Object.new)
    assert_empty FailureReport.keys
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
