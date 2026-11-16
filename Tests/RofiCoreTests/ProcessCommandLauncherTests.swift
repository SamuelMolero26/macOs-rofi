// Not Foundation: see HistoryTests.swift.
import RofiCore
import Testing

// Contract: the real `ListGenerator`, `execute_generator` (source/helper.c:
// 562-583) read as get_apps_external reads it (source/modes/run.c:185-240).
// These are the only tests that spawn a process, `/bin/sh`.
@Suite struct ProcessCommandLauncherTests {
    private let clock = ContinuousClock()

    // run.c:194-199: one entry per line, only the trailing newline removed.
    @Test func returnsTheStdoutLines_run_c_194() {
        #expect(generateWithProcess(["/bin/sh", "-c", "printf 'a\\nb c\\n\\nd'"]) == .success(["a", "b c", "", "d"]))
        #expect(generateWithProcess(["/bin/sh", "-c", "printf 'x\\r\\n'"]) == .success(["x\r"]))
        #expect(generateWithProcess(["/bin/sh", "-c", "true"]) == .success([]))
    }

    // helper.c:570: G_SPAWN_SEARCH_PATH, so a bare name is looked up.
    @Test func resolvesABareNameThroughPath_helper_c_570() {
        #expect(generateWithProcess(["sh", "-c", "echo hi"]) == .success(["hi"]))
    }

    // helper.c:572-578.
    @Test func aCommandThatCannotStartFails_helper_c_572() {
        guard case .failure(let error) = generateWithProcess(["/nonexistent/lister", "-a"]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.command == "/nonexistent/lister -a")
        #expect(generateWithProcess([]) == .failure(ApplicationLaunchFailure(command: "", reason: "empty command")))
    }

    @Test func aSlowCommandTimesOut() {
        let start = clock.now
        let result = generateWithProcess(["/bin/sh", "-c", "sleep 5"], timeout: 0.3)
        #expect(clock.now - start < .seconds(2))
        #expect(result == .failure(ApplicationLaunchFailure(command: "/bin/sh -c sleep 5", reason: timedOut)))
    }

    // The child exits at once, but a background grandchild keeps stdout open,
    // so end of file never arrives; the deadline still bounds the call.
    @Test func aGrandchildHoldingStdoutStillTimesOut() {
        let start = clock.now
        let command = "sleep 5 </dev/null 2>/dev/null & echo a"
        let result = generateWithProcess(["/bin/sh", "-c", command], timeout: 0.3)
        #expect(clock.now - start < .seconds(2))
        #expect(result == .failure(ApplicationLaunchFailure(command: "/bin/sh -c " + command, reason: timedOut)))
    }

    private let timedOut = "list command timed out after 0.3 seconds"
}
