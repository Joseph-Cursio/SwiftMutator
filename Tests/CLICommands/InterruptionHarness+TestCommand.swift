import XCTest

extension InterruptionHarness {
    /// Where the test command hangs: in the coverage run, in the baseline, or in each mutant's run.
    enum Phase: String {
        case coverage
        case baseline
        case mutants
        /// In each mutant's run, as `mutants`, once worker 1 has filled its clone with files, so that removing the
        /// clone keeps a stopping SwiftMutator busy for a while.
        case mutantsWithALargeWorkerClone
        /// Nowhere: each mutant's run shows a failed test, so SwiftMutator kills it there, having started a `sleep`
        /// that no listing of its tree finds, as its parent has ended.
        case mutantsWithAnUnlistedProcess
        /// Nowhere: each mutant's run takes 3 seconds, in a `sleep` its shell waits for, and passes. Not in the
        /// background, as `hang`'s: on Linux, the test command starts with SIGCHLD blocked, and dash's `wait` for a
        /// background job then misses its end.
        case slowMutants
    }

    /// Where the test command hangs, it writes down its own ID, starts a `sleep` whose odd length makes one left
    /// behind easy to find, writes down that ID too, and waits. A hanging run is then a tree, as `swift test` is.
    /// `$0` is the argument SwiftMutator adds, `--enable-code-coverage` in the coverage run. The test command runs in
    /// its worker's folder.
    static let testCommand = """
        hang() {
            echo $$ > "$INTERRUPT_TEST_MARKERS/sh.$$"
            /bin/sleep 60.7 & echo $! > "$INTERRUPT_TEST_MARKERS/sleep.$!"
            wait
        }
        slow() {
            echo $$ > "$INTERRUPT_TEST_MARKERS/sh.$$"
            /bin/sh -c 'echo $$ > "$INTERRUPT_TEST_MARKERS/sleep.$$"; exec /bin/sleep 3'
            exit 0
        }
        unlisted() {
            echo $$ > "$INTERRUPT_TEST_MARKERS/sh.$$"
            (/bin/sleep 60.8 & echo $! > "$INTERRUPT_TEST_MARKERS/sleep.$!")
            echo "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
            exec /bin/sleep 60.9
        }
        fill() { mkdir "$1" && cd "$1" && /usr/bin/seq -f "file%g" 10000 | /usr/bin/xargs /usr/bin/touch; }
        worker=$(pwd -P)
        case "$INTERRUPT_TEST_PHASE:$0" in
            coverage:--enable-code-coverage) hang;;
            slowMutants:*) [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] && slow;;
            mutantsWithAnUnlistedProcess:*) [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] && unlisted; exit 0;;
            baseline:*) [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] || hang;;
            mutantsWithALargeWorkerClone:*)
                case "$worker" in *_worker1.noindex) [ -d "$worker/files" ] || (fill "$worker/files");; esac;;
        esac
        [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] && hang
        exit 0
        """
}
