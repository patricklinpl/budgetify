# Retries ONE read-only statement (a text or value assertion, never a click or a
# key) when chromedriver reports exactly one staleness error: a node matched by a
# query was replaced by a Turbo render before Capybara's visibility check ran.
# Capybara's own retry skips it because the driver reports it as UnknownError.
#
# One total deadline covers the statement and every retry. Each attempt runs with
# only the time left (never a fresh full wait), the pause between retries is
# capped by the time left, and once the deadline has passed the error is raised
# unchanged. Any other error is raised unchanged at once.
module StaleNodeRead
  STALE_NODE_MESSAGE = "Node with given id does not belong to the document".freeze
  RETRY_PAUSE = 0.05

  def settle_read(wait: nil, clock: nil, sleeper: nil, waiter: nil, &read)
    wait ||= Capybara.default_max_wait_time
    clock ||= -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    sleeper ||= ->(seconds) { sleep seconds }
    waiter ||= ->(seconds, &block) { Capybara.using_wait_time(seconds, &block) }
    deadline = clock.call + wait
    begin
      waiter.call([ deadline - clock.call, 0 ].max, &read)
    rescue Selenium::WebDriver::Error::UnknownError => e
      raise unless e.message.include?(STALE_NODE_MESSAGE)

      left = deadline - clock.call
      raise unless left.positive?

      sleeper.call([ RETRY_PAUSE, left ].min)
      retry
    end
  end
end
