require "test_helper"
require_relative "chromedriver_timeline"
require "tempfile"

# [engineering] The skeleton of ChromeDriver's raw log may carry timing and
# fixed tokens only. Every raw record type below carries a CANARY marker; none of
# it may reach the output. Synthetic data only.
class ChromedriverTimelineTest < ActiveSupport::TestCase
  SID = "0123456789abcdef0123456789abcdef".freeze

  def stamp(offset, level = "INFO")
    format("[%.3f][%s]: ", 1_795_591_700 + offset, level)
  end

  def skeleton_of(raw, from: 0)
    Tempfile.create([ "driver", ".log" ], binmode: true) do |f|
      f.write(raw)
      f.flush
      ChromedriverTimeline.skeleton(f.path, from: from)
    end
  end

  def corpus
    lines = []
    # WebDriver commands and responses with payloads (single and multi line)
    lines << "#{stamp(0)}[#{SID}] COMMAND ClickElement {"
    lines << '   "id": "f.CANARY_NODE_ID.d.CANARY_DOC_ID.e.1"'
    lines << "}"
    lines << "#{stamp(0.001, 'DEBUG')}DevTools WebSocket Command: Input.dispatchMouseEvent (id=315) (session_id=CANARY_SESSION) CANARY_TARGET {"
    lines << '   "type": "mousePressed", "x": 1, "y": 2, "value": "CANARY_FIELD_VALUE"'
    lines << "}"
    lines << "#{stamp(0.002, 'DEBUG')}DevTools WebSocket Response: Input.dispatchMouseEvent (id=315) (session_id=CANARY_SESSION) CANARY_TARGET {"
    lines << "#{stamp(0.003)}Waiting for pending navigations..."
    lines << "#{stamp(0.003)}Done waiting for pending navigations. Status: ok"
    lines << "#{stamp(0.004)}[#{SID}] RESPONSE ClickElement"
    lines << "#{stamp(0.200, 'DEBUG')}DevTools WebSocket Event: Page.frameNavigated (session_id=CANARY_SESSION) CANARY_TARGET {"
    lines << '   "frame": {"url": "http://127.0.0.1/CANARY_URL?token=CANARY_TOKEN"}'
    lines << "}"
    # Records that carry content and must be dropped whole
    lines << "#{stamp(0.201)}[#{SID}] COMMAND ExecuteScript {"
    lines << '   "script": "document.cookie = \'CANARY_COOKIE\'; password = \'CANARY_PASSWORD\'"'
    lines << "}"
    lines << "#{stamp(0.202)}[#{SID}] RESPONSE GetElementText \"CANARY_PAGE_TEXT\\nsecond line\""
    lines << "#{stamp(0.203)}[#{SID}] RESPONSE GetUrl \"http://127.0.0.1:1/CANARY_URL\""
    lines << "#{stamp(0.204)}[#{SID}] RESPONSE FindElement unknown error: CANARY_ERROR_TEXT Node with given id does not belong to the document"
    lines << 'unknown error: unhandled inspector error: {"code":-32000,"message":"CANARY_UNKNOWN_ERROR"}'
    # Tokens outside the allowlists, forged tails, odd statuses
    lines << "#{stamp(0.205)}[#{SID}] COMMAND EvilVerbCANARYVERB {"
    lines << "#{stamp(0.206, 'DEBUG')}DevTools WebSocket Event: Page.CANARYEVENT (session_id=X) T {"
    lines << "#{stamp(0.207, 'DEBUG')}DevTools WebSocket Command: Runtime.evaluate (id=9) (session_id=X) T { \"expression\": \"CANARY_EXPRESSION\" }"
    lines << "#{stamp(0.208)}Done waiting for pending navigations. Status: unexpected alert open"
    lines << "#{stamp(0.2085)}Done waiting for pending navigations. Status: CANARY_STATUS"
    lines << "#{stamp(0.209)}Done waiting for pending navigations. Status: ok CANARY_TAIL"
    lines << "#{stamp(0.210)}Waiting for pending navigations... CANARY_TAIL"
    lines << "#{stamp(0.211)}[#{SID}] RESPONSE ClickElementCANARY_GLUED"
    lines << "#{stamp(0.212)}[#{SID}] COMMAND ClickElement CANARY_TRAILING"
    lines << "#{stamp(0.213)}[SESSION_CANARY_NOT_HEX] COMMAND ClickElement {"
    lines << "#{stamp(0.214, 'ERROR')}[#{SID}] COMMAND ClickElement {"
    # Malformed input
    lines << "\xFF\xFE\x00CANARY_BINARY\x00\x1B[31mCANARY_ANSI"
    lines << "#{stamp(0.215)}[#{SID}] COMMAND ClickElement\rCANARY_CR"
    lines << "#{stamp(0.216)}#{'A' * 100_000}CANARY_LONG"
    lines << "#{stamp(0.217)}[#{SID}] COMMAND #{'B' * 100_000}"
    lines << "[notatime][INFO]: CANARY_NO_STAMP"
    lines << "#{stamp(0.218)}Done waiting for pending navigations. Status: ok"
    lines.join("\n") + "\n"
  end

  test "[engineering] no canary from any raw record type reaches the output" do
    result = skeleton_of(corpus)
    report = ChromedriverTimeline.report("SomeTest#test_x", result)

    assert_no_match(/CANARY|SESSION|0123456789abcdef|127\.0\.0\.1|token|cookie|password|http/i, report)
    assert result.lines.any?, "the allowlisted records are still emitted"
    result.lines.each { |line| assert_match ChromedriverTimeline::LINE_FORMAT, line }
  end

  test "[engineering] allowlisted records come out as relative ms, kind, token and status" do
    result = skeleton_of(corpus)

    assert_equal [
      "+0ms C ClickElement",
      "+1ms D Input.dispatchMouseEvent",
      "+2ms d Input.dispatchMouseEvent",
      "+3ms W wait",
      "+3ms W done ok",
      "+4ms R ClickElement",
      "+200ms E Page.frameNavigated"
    ], result.lines.first(7)
    assert_equal "+218ms W done ok", result.lines.last
    assert_includes result.lines, "+208ms W done other"
  end

  test "[engineering] unknown verbs, events, tails and malformed lines are dropped and counted, not printed" do
    result = skeleton_of(corpus)

    assert_operator result.dropped, :>=, 20
    refute(result.lines.any? { |l| l.include?("EvilVerb") || l.include?("Runtime.evaluate") || l.include?("CANARYEVENT") })
  end

  test "[engineering] a raw log with an error or UnknownError text adds nothing but its timing records" do
    raw = "#{stamp(0)}[#{SID}] COMMAND FindElements {\n" \
          "#{stamp(1)}[#{SID}] RESPONSE FindElements unknown error: Node with given id does not belong to the document CANARY_UNKNOWN\n" \
          "{\"code\":-32000,\"message\":\"Node with given id does not belong to the document\"}\n"
    result = skeleton_of(raw)

    assert_equal [ "+0ms C FindElements", "+1000ms R FindElements" ], result.lines
    assert_no_match(/CANARY|Node with given id|32000/, ChromedriverTimeline.report("T#t", result))
  end

  test "[engineering] output is bounded in records" do
    raw = (0...2000).map { |i| "#{stamp(i / 1000.0)}Waiting for pending navigations...\n" }.join
    result = skeleton_of(raw)

    assert_equal ChromedriverTimeline::MAX_RECORDS, result.lines.size
    assert result.truncated
  end

  test "[engineering] output is bounded in bytes" do
    raw = (0...ChromedriverTimeline::MAX_RECORDS).map do |i|
      "#{stamp(i * 100.0, 'DEBUG')}DevTools WebSocket Command: Input.dispatchMouseEvent (id=#{i}) (session_id=X) T {\n"
    end.join
    result = skeleton_of(raw)

    assert_operator result.lines.sum { |l| l.bytesize + 1 }, :<=, ChromedriverTimeline::MAX_OUTPUT_BYTES
    assert_operator result.lines.size, :<, ChromedriverTimeline::MAX_RECORDS
    assert result.truncated
  end

  test "[engineering] a start offset keeps only what was written after it and skips a partial first line" do
    first = "#{stamp(0)}[#{SID}] COMMAND GetUrl {\n"
    second = "#{stamp(5)}[#{SID}] COMMAND ClickElement {\n"
    result = skeleton_of(first + second, from: first.bytesize - 6)

    assert_equal [ "+0ms C ClickElement" ], result.lines
  end

  test "[engineering] a missing log gives an empty result, not an error" do
    result = ChromedriverTimeline.skeleton("/nonexistent/driver.log")

    assert_empty result.lines
  end

  test "[engineering] the timeline is off unless the directory variable or the opt-in variable is set" do
    with_env("CHROMEDRIVER_TIMELINE_DIR" => nil, "CHROMEDRIVER_TIMELINE" => nil, "CI" => "true") { assert_not ChromedriverTimeline.enabled? }
    with_env("CHROMEDRIVER_TIMELINE_DIR" => "/tmp/x", "CHROMEDRIVER_TIMELINE" => nil) { assert ChromedriverTimeline.enabled? }
    with_env("CHROMEDRIVER_TIMELINE_DIR" => nil, "CHROMEDRIVER_TIMELINE" => "1") { assert ChromedriverTimeline.enabled? }
  end

  private

  def with_env(vars)
    saved = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
