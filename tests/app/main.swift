// Entry point of the app tests: runs every topic file in tests/app/. Run: tests/app-tests.sh

import AppKit

MainActor.assumeIsolated {
    suite_rows()
    suite_logos_reload_rollback()
    suite_build_logs_claude()
    suite_safe_deploys_providers()
    suite_autofix_savings()
    suite_palette_settings()
    suite_mac_logic()
    suite_queue_phone_link()
    suite_mac_track()
    suite_wave2_tool_run()
    suite_settings_status()
    suite_ci_lane_contract()
    suite_rounds_cost_quiet()
    suite_ux2()
    suite_ux()
    insightsAppTests(expect); insightsAppTests2(expect)
}

if fails == 0 { print("All app tests passed.") } else { print("\(fails) failed."); exit(1) }
