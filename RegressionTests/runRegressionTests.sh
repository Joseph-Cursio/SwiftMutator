#!/bin/sh

echo "🦕🦕🦕🦕🦕🦕🦕🦕 Regression Testing has started 🦕🦕🦕🦕🦕🦕🦕🦕"

muterdir="../../.build/debug"
samplesdir="../../RegressionTests/samples"

# Runs SwiftMutator on a project in Repositories/ and saves its report as a sample, or stops the script: a run that
# fails or writes no report has nothing to compare. An earlier run's report goes first, or it would be saved in this
# run's place and could match its snapshot. Run from the repository's root: project, sample's name, extra arguments.
run_on_project() {
    project="$1"
    sample="$2"
    shift 2

    cd "./Repositories/$project" || exit 1
    rm -f ./muterReport.json

    "$muterdir"/swift-mutator --skip-update-check --format json --output muterReport.json "$@"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "SwiftMutator failed on $project with status $status, so the regression tests didn't run" >&2
        exit "$status"
    fi
    if [ ! -f ./muterReport.json ]; then
        echo "SwiftMutator wrote no report for $project, so the regression tests didn't run" >&2
        exit 1
    fi

    cp ./muterReport.json "$samplesdir/$sample" || exit 1
    cd ../.. || exit 1
}

rm -rf ./RegressionTests/samples
mkdir -p ./RegressionTests/samples

echo "Running Regression Test on BonMot..."
run_on_project BonMot bonmot_regression_test_output.json

echo "Running Regression Test on Parser Combinator..."
run_on_project FFCParserCombinator parsercombinator_regression_test_output.json --skip-coverage

echo "Running Regression Test on Project With Concurrency..."
run_on_project ProjectWithConcurrency projectwithconcurrency_test_output.json --skip-coverage

swift test --filter 'RegressionTests'

exitCode=$?

exit $exitCode

echo "🦖🦖🦖🦖🦖🦖🦖🦖 Regression Testing has finished 🦖🦖🦖🦖🦖🦖🦖🦖"
