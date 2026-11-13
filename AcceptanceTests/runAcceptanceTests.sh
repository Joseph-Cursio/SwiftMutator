#!/bin/sh

echo "📴📴📴📴📴📴📴 Acceptance Testing has started 📴📴📴📴📴📴📴"

muterdir="../../../.build/debug"
samplesdir="../../samples"

# The script's own stderr, for messages that a run's redirection mustn't swallow.
exec 3>&2

# Runs SwiftMutator with the arguments after the first, and stops the script unless it exits with the first. A run
# that exits otherwise didn't do what its sample is for, such as a project meant to fail its baseline that no longer
# builds, and its output could still pass the checks that read it.
muter() {
    expected="$1"
    shift
    "$muterdir"/swift-mutator "$@"
    actual=$?
    if [ "$actual" -ne "$expected" ]; then
        echo "SwiftMutator exited with $actual, not $expected, in $(pwd): swift-mutator $*" >&3
        echo "So the acceptance tests didn't run." >&3
        exit 1
    fi
}

echo "🧹 Cleaning up from prior acceptance test runs..."
rm -rf ./AcceptanceTests/samples/muter_logs
rm -rf ./AcceptanceTests/samples
rm -rf ./AcceptanceTests/Repositories

mkdir -p ./AcceptanceTests/samples
mkdir -p ./AcceptanceTests/samples/muter_logs

cp -R ./Repositories ./AcceptanceTests || exit 1

echo "🧟‍♂️ Running SwiftMutator on an iOS codebase with a test suite..."
cd ./AcceptanceTests/Repositories/ExampleApp || exit 1

echo " > Creating a configuration file..."
# The repository has one, which init leaves as it is unless forced.
muter 1 init
muter 0 init --force
cp ./muter.conf.yml "$samplesdir"/created_iOS_config.yml

echo " > Running in CLI mode..."
rm -rf ../ExampleApp_muter_logs 2>/dev/null
muter 0 --skip-coverage --skip-update-check --verbose > "$samplesdir"/muters_output.txt 2>"$samplesdir"/muters_output.stderr.log
echo " > Copying logs..."
cp -R ../ExampleApp_muter_logs/. "$samplesdir"/muter_logs/
rm -rf ../ExampleApp_muter_logs

echo " > Running with coverage"
muter 0 --skip-update-check > "$samplesdir"/muters_with_coverage_output.txt 2>"$samplesdir"/muters_with_coverage_output.stderr.log
rm -rf ../ExampleApp_muter_logs

echo " > Running in Xcode mode..."
muter 0 --skip-coverage --skip-update-check --format xcode > "$samplesdir"/muters_xcode_output.txt 2>"$samplesdir"/muters_xcode_output.stderr.log
rm -rf ../ExampleApp_muter_logs

echo " > Running with --filesToMutate flag"
muter 0 --skip-coverage --skip-update-check --files-to-mutate "/ExampleApp/Module.swift" > "$samplesdir"/muters_files_to_mutate_output.txt 2>"$samplesdir"/muters_files_to_mutate_output.stderr.log
rm -rf ../ExampleApp_muter_logs

echo " > Creating muter's test plan"
muter 0 mutate-without-running --skip-update-check > "$samplesdir"/muters_mutate_without_running_output.txt 2>"$samplesdir"/muters_mutate_without_running_output.stderr.log
cp ./muter-mappings.json "$samplesdir"/created_muter-mappings.json
rm -rf ../ExampleApp_muter_logs

echo " > Running with a test plan"
muter 0 run-without-mutating --skip-update-check muter-mappings.json > "$samplesdir"/muters_output_with_test_plan.txt
rm -rf ../ExampleApp_muter_logs

rm muter-mappings.json # cleanup the created mutation test run file for the next test run
rm muter.conf.yml # cleanup the created configuration file for the next test run
cd ../.. || exit 1

echo "🧟‍♂️ Initializing SwiftMutator on a macOS codebase with a test suite..."
cd ./Repositories/ExampleMacOSApp || exit 1

echo " > Creating a configuration file..."
muter 0 init
cp ./muter.conf.yml "$samplesdir"/created_macOS_config.yml

echo " > Cleaning up after test..."
rm muter.conf.yml # cleanup the created configuration file for the next test run
cd ../.. || exit 1

echo "🧟‍♂️ Running SwiftMutator on an empty example codebase..."
cd ./Repositories/EmptyExampleApp || exit 1

# 255: no code to mutate is an error, unlike a --since run with nothing changed.
echo " > Running in CLI mode with custom configuration path..."
muter 255 --skip-coverage --skip-update-check --configuration "$(pwd)/configuration/muter.conf.yml" > "$samplesdir"/muters_empty_state_output.txt 2>"$samplesdir"/muters_empty_state_output.stderr.log
cd ../.. || exit 1

echo "🧟‍♂️ Running SwiftMutator on an example test suite that fails..."
cd ./Repositories/ProjectWithFailures || exit 1

# 3: the baseline failed.
echo " > Running in CLI mode..."
rm -rf ../ProjectWithFailures_muter_logs 2>/dev/null
muter 3 --skip-coverage --skip-update-check > "$samplesdir"/muters_aborted_testing_output.txt 2>"$samplesdir"/muters_aborted_testing_output.stderr.log
rm -rf ../ProjectWithFailures_muter_logs
cd ../.. || exit 1

echo " > Running SwiftMutator in a project that times out..."
cd ./Repositories/ProjectWithTimeout || exit 1

rm -rf ../ProjectWithTimeout_muter_logs 2>/dev/null
muter 0 --skip-coverage --skip-update-check > "$samplesdir"/muters_timeout_output.txt 2>"$samplesdir"/muters_timeout_output.stderr.log
rm -rf ../ProjectWithTimeout_muter_logs

cd ../.. || exit 1

echo "Running SwiftMutator's help command..."
cd ./Repositories/ExampleApp || exit 1

echo " > Running help command..."
muter 0 help > "$samplesdir"/muters_help_output.txt

echo " > Running init help command..."
muter 0 help init > "$samplesdir"/muters_init_help_output.txt

echo " > Running run help command..."
muter 0 help run > "$samplesdir"/muters_run_help_output.txt

echo " > Running operators help command..."
muter 0 help operator > "$samplesdir"/muters_operator_help_output.txt

echo " > Running report help command..."
muter 0 help report > "$samplesdir"/muters_report_help_output.txt

echo " > Running all operators command..."
muter 0 operator all > "$samplesdir"/muters_operator_all_output.txt

cd ../../.. || exit 1

rm -rf ./AcceptanceTests/Repositories

echo "Running tests..."

swift test --filter 'AcceptanceTests'

exitCode=$?

echo "📳📳📳📳📳📳📳 Acceptance Testing has finished 📳📳📳📳📳📳📳"

exit $exitCode
