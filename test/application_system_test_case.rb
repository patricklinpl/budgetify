require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # Test-driver diagnostics for lost clicks (the recurring Cancel failure).
  # Native Selenium clicks stay as they are. Install the log before the
  # interaction; when an expectation then fails, the message carries what the
  # page saw: every pointer event with its target and time, and a snapshot of
  # the window, focus, ready state and what sits at the center of each named
  # control. That separates "the click never reached the page" (no events),
  # "it hit another element" (target differs), and "the page was not ready".
  def install_input_log
    page.execute_script(INPUT_LOG_JS)
  end

  def input_diagnostics(*labels)
    page.evaluate_script(<<~JS)
      (() => {
        const labels = #{labels.to_json};
        const controls = labels.map((label) => {
          const el = [...document.querySelectorAll("a, button")].find((x) => x.textContent.trim() === label);
          if (!el) return label + ": not found";
          const r = el.getBoundingClientRect();
          const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
          const top = document.elementFromPoint(cx, cy);
          return label + ": rect=" + [r.x, r.y, r.width, r.height].map(Math.round) + " center=" + Math.round(cx) + "," + Math.round(cy) + " top=" + (top ? top.tagName + " '" + (top.textContent || "").trim().slice(0, 16) + "'" : "none") + " offscreen=" + (cy < 0 || cy > innerHeight || cx < 0 || cx > innerWidth);
        });
        return JSON.stringify({
          path: location.pathname,
          window: [innerWidth, innerHeight],
          outer: [outerWidth, outerHeight],
          dpr: devicePixelRatio,
          focus: document.hasFocus(),
          visibility: document.visibilityState,
          readyState: document.readyState,
          scrollY: Math.round(scrollY),
          openDialogs: document.querySelectorAll("dialog[open]").length,
          controls,
          inputLog: window.__inputLog || "not installed"
        });
      })()
    JS
  rescue => e
    "diagnostics unavailable: #{e.class}: #{e.message}"
  end

  # Re-raises an expectation failure with the diagnostics appended.
  def with_input_diagnostics(*labels)
    yield
  rescue Minitest::Assertion, Capybara::ExpectationNotFound => e
    raise e.class, "#{e.message}\nInput diagnostics: #{input_diagnostics(*labels)}"
  end

  INPUT_LOG_JS = <<JS
window.__inputLog = [];
["pointerdown", "mousedown", "mouseup", "click"].forEach((type) => {
  document.addEventListener(type, (e) => {
    const el = e.target;
    window.__inputLog.push(Math.round(performance.now()) + "ms " + type + " " + el.tagName + " '" + (el.textContent || "").trim().slice(0, 16) + "' @" + Math.round(e.clientX) + "," + Math.round(e.clientY));
  }, true);
});
JS
  end
