#!/bin/sh

echo "📴📴📴📴📴📴📴 Acceptance Testing has started 📴📴📴📴📴📴📴"

muterdir="../../../.build/debug"
samplesdir="../../samples"

echo "🧹 Cleaning up from prior acceptance test runs..."
rm -rf ./AcceptanceTests/samples/muter_logs
rm -rf ./AcceptanceTests/samples
rm -rf ./AcceptanceTests/Repositories

mkdir -p ./AcceptanceTests/samples
mkdir -p ./AcceptanceTests/samples/muter_logs

cp -R ./Repositories ./AcceptanceTests

echo "🧟‍♂️ Running Muter on an iOS codebase with a test suite..."
cd ./AcceptanceTests/Repositories/ExampleApp

echo " > Creating a configuration file..."
"$muterdir"/swift-mutator init
cp ./muter.conf.yml "$samplesdir"/created_iOS_config.yml

echo " > Running in CLI mode..."
rm -rf ./muter_logs 2>/dev/null
"$muterdir"/swift-mutator --skip-coverage --skip-update-check > "$samplesdir"/muters_output.txt 2>/dev/null
echo " > Copying logs..."
cp -R ./muter_logs "$samplesdir"/
rm -rf ./muter_logs

echo " > Running with coverage"
"$muterdir"/swift-mutator --skip-update-check > "$samplesdir"/muters_with_coverage_output.txt 2>/dev/null
rm -rf ./muter_logs

echo " > Running in Xcode mode..."
"$muterdir"/swift-mutator --skip-coverage --skip-update-check --format xcode > "$samplesdir"/muters_xcode_output.txt 2>/dev/null
rm -rf ./muter_logs

echo " > Running with --filesToMutate flag"
"$muterdir"/swift-mutator --skip-coverage --skip-update-check --files-to-mutate "/ExampleApp/Module.swift" > "$samplesdir"/muters_files_to_mutate_output.txt 2>/dev/null
rm -rf ./muter_logs

echo " > Creating muter's test plan"
"$muterdir"/swift-mutator mutate-without-running --skip-update-check > /dev/null
cp ./muter-mappings.json "$samplesdir"/created_muter-mappings.json
rm -rf ./muter_logs

echo " > Running with a test plan"
"$muterdir"/swift-mutator run-without-mutating --skip-update-check muter-mappings.json > "$samplesdir"/muters_output_with_test_plan.txt
rm -rf ./muter_logs

rm muter-mappings.json # cleanup the created mutation test run file for the next test run
rm muter.conf.yml # cleanup the created configuration file for the next test run
cd ../..

echo "🧟‍♂️ Initializing Muter on an macOS codebase with a test suite..."
cd ./Repositories/ExampleMacOSApp

echo " > Creating a configuration file..."
"$muterdir"/swift-mutator init
cp ./muter.conf.yml "$samplesdir"/created_macOS_config.yml

echo " > Cleaning up after test..."
rm muter.conf.yml # cleanup the created configuration file for the next test run
cd ../..

echo "🧟‍♂️ Running Muter on an empty example codebase..."
cd ./Repositories/EmptyExampleApp

echo " > Running in CLI mode with custom configuration path..."
"$muterdir"/swift-mutator --skip-coverage --skip-update-check --configuration "$(pwd)/configuration/muter.conf.yml" > "$samplesdir"/muters_empty_state_output.txt 2>/dev/null
cd ../..

echo "🧟‍♂️ Running Muter on an example test suite that fails..."
cd ./Repositories/ProjectWithFailures

echo " > Running in CLI mode..."
rm -rf ./muter_logs 2>/dev/null
"$muterdir"/swift-mutator --skip-coverage --skip-update-check > "$samplesdir"/muters_aborted_testing_output.txt 2>/dev/null
rm -rf ./muter_logs
cd ../..

echo " > Running Muter in a project that times out..."
cd ./Repositories/ProjectWithTimeout

rm -rf ./muter_logs 2>/dev/null
"$muterdir"/swift-mutator --skip-coverage --skip-update-check > "$samplesdir"/muters_timeout_output.txt 2>/dev/null
rm -rf ./muter_logs

cd ../..

echo "Running Muter's help command..."
cd ./Repositories/ExampleApp

echo " > Running help command..."
"$muterdir"/swift-mutator help > "$samplesdir"/muters_help_output.txt

echo " > Running init help command..."
"$muterdir"/swift-mutator help init > "$samplesdir"/muters_init_help_output.txt

echo " > Running run help command..."
"$muterdir"/swift-mutator help run > "$samplesdir"/muters_run_help_output.txt

echo " > Running operators help command..."
"$muterdir"/swift-mutator help operator > "$samplesdir"/muters_operator_help_output.txt

echo " > Running all operators command..."
"$muterdir"/swift-mutator operator all > "$samplesdir"/muters_operator_all_output.txt

cd ../../..

rm -rf ./AcceptanceTests/Repositories

echo "Running tests..."

swift test --filter 'AcceptanceTests' 2>/dev/null

exitCode=$?

exit $exitCode

echo "📳📳📳📳📳📳📳 Acceptance Testing has finished 📳📳📳📳📳📳📳"
