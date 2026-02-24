#!/bin/bash
set -euo pipefail

# Generate GitHub Actions Summary for H2 Compliance Tests
# Parses CT log HTML to discover groups and their pass/fail status.
# Usage: ./generate_compliance_summary.sh <ct_log_dir>

CT_LOG_DIR="${1:-_build/test/logs}"
OUTPUT_FILE="${GITHUB_STEP_SUMMARY:-/tmp/summary.md}"

# Find the latest test run
LATEST_RUN=$(find "$CT_LOG_DIR" -name "suite.log.html" -path "*h2_compliance_SUITE.logs/*" -type f 2>/dev/null | sort -r | head -1)

if [ -z "$LATEST_RUN" ]; then
    echo "No test results found in $CT_LOG_DIR"
    exit 1
fi

echo "Parsing test results from: $LATEST_RUN"

# Parse test results from CT log HTML into a temp file.
# Each line: <group_name> <OK|FAILED>
RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

while IFS= read -r line; do
    # Match lines like: h2_compliance_suite.run_connection_preface ... Ok/FAILED
    group=""
    status=""
    case "$line" in
        *h2_compliance_suite.run_*)
            # Extract group name after "run_"
            group=$(echo "$line" | sed -n 's/.*h2_compliance_suite\.run_\([a-z_0-9]*\).*/\1/p')
            ;;
    esac

    if [ -z "$group" ]; then
        continue
    fi

    case "$line" in
        *'<font color="red">FAILED</font>'*)
            status="FAILED" ;;
        *'<font color='*'>Ok</font>'*|*'<font color='*'>ok</font>'*)
            status="OK" ;;
    esac

    if [ -n "$status" ]; then
        # Only record first result per group
        if ! grep -q "^${group} " "$RESULTS_FILE" 2>/dev/null; then
            echo "$group $status" >> "$RESULTS_FILE"
        fi
    fi
done < "$LATEST_RUN"

TOTAL=$(wc -l < "$RESULTS_FILE" | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
    echo "Could not parse any test results from the log."
    echo "# HTTP/2 Compliance Test Results" > "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "No test results could be parsed from CT logs." >> "$OUTPUT_FILE"
    exit 1
fi

echo "Found $TOTAL test groups"

PASSED=$(grep -c " OK$" "$RESULTS_FILE" || true)
FAILED=$(grep -c " FAILED$" "$RESULTS_FILE" || true)

if [ "$TOTAL" -gt 0 ]; then
    SUCCESS_RATE=$((PASSED * 100 / TOTAL))
else
    SUCCESS_RATE=0
fi

echo "Results: $PASSED passed, $FAILED failed ($SUCCESS_RATE% pass rate)"

# Pretty-print a group name: stream_states -> Stream States
pretty_name() {
    echo "$1" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
}

# Build the summary markdown
{
    echo "# HTTP/2 Compliance Test Results"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        echo "## All $TOTAL Groups Passed"
        echo ""
        echo "- **Groups**: $TOTAL"
        echo "- **Pass Rate**: 100%"
    else
        echo "## $PASSED / $TOTAL Groups Passed ($SUCCESS_RATE%)"
        echo ""
        echo "- **Passed**: $PASSED"
        echo "- **Failed**: $FAILED"
        echo ""
        echo "### Failed Groups"
        echo ""
        grep " FAILED$" "$RESULTS_FILE" | while read -r g _; do
            echo "- $(pretty_name "$g")"
        done
    fi

    echo ""
    echo "## All Groups"
    echo ""
    echo "| Group | Status |"
    echo "|-------|--------|"
    while read -r group status; do
        name=$(pretty_name "$group")
        if [ "$status" = "OK" ]; then
            echo "| $name | Pass |"
        else
            echo "| $name | **FAIL** |"
        fi
    done < "$RESULTS_FILE"

} > "$OUTPUT_FILE"

echo "Summary written to: $OUTPUT_FILE"
echo "  Passed: $PASSED/$TOTAL"
echo "  Failed: $FAILED/$TOTAL"
