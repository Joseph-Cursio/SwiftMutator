extension ResumeHarness {
    /// Writes down the active mutant of each run, or `baseline` for a run with none. Kills the mutants in Checks.swift,
    /// printing the line Swift Testing shows an issue of `check()` with, then the line it ends a failed run with, but
    /// first hangs in each while the `hang` marker exists: it writes down its own ID, starts a `sleep` whose odd length
    /// makes one left behind easy to find, writes down that ID too, and waits. The mutants in Bounds.swift survive, and
    /// the baseline passes. The issue's line can stop a run there, as `buildSystem: swift` stops runs at their first
    /// failed test.
    static let testCommand = """
        mutant=$(head -n 1 "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" 2>/dev/null)
        echo "${mutant:-baseline}" >> "$RESUME_TEST_MARKERS/ran"
        case "$mutant" in
            Checks_*)
                if [ -e "$RESUME_TEST_MARKERS/hang" ]; then
                    echo $$ > "$RESUME_TEST_MARKERS/sh.$$"
                    /bin/sleep 60.7 & echo $! > "$RESUME_TEST_MARKERS/sleep.$!"
                    wait
                fi
                echo "✘ Test check() recorded an issue at ChecksTests.swift:3:5: Expectation failed"
                echo "✘ Test run with 1 test failed after 0.001 seconds with 1 issue."
                exit 1;;
        esac
        exit 0
        """
}
