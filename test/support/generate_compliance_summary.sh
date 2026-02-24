#!/bin/bash
set -euo pipefail

# Generate GitHub Actions Summary for H2 Compliance Tests
# Usage: ./generate_compliance_summary.sh <ct_log_dir>

CT_LOG_DIR="${1:-_build/test/logs}"
OUTPUT_FILE="${GITHUB_STEP_SUMMARY:-/tmp/summary.md}"

# Find the latest test run
LATEST_RUN=$(find "$CT_LOG_DIR" -name "suite.log.html" -path "*/h2_compliance_SUITE.logs/*" -type f 2>/dev/null | sort -r | head -1)

if [ -z "$LATEST_RUN" ]; then
    echo "⚠️  No test results found in $CT_LOG_DIR"
    echo "Tests may not have run yet."
    exit 1
fi

echo "📊 Parsing test results from: $LATEST_RUN"

# Parse test results - look for test group outcomes
declare -A TEST_STATUS

# Parse the HTML log for test results
# Look for patterns like: h2_compliance_SUITE:run_connection_preface ok
# or: h2_compliance_SUITE:run_connection_preface FAILED

# Method 1: Try to parse from suite log
while IFS= read -r line; do
    if [[ "$line" =~ h2_compliance_SUITE:run_([a-z_]+).*\<font\ color=\"green\"\>ok\<\/font\> ]] || \
       [[ "$line" =~ h2_compliance_SUITE\.run_([a-z_]+):.*ok ]]; then
        group="${BASH_REMATCH[1]}"
        TEST_STATUS["$group"]="✅"
    elif [[ "$line" =~ h2_compliance_SUITE:run_([a-z_]+).*FAILED ]] || \
         [[ "$line" =~ h2_compliance_SUITE\.run_([a-z_]+):.*FAILED ]]; then
        group="${BASH_REMATCH[1]}"
        TEST_STATUS["$group"]="❌"
    fi
done < "$LATEST_RUN"

# Method 2: If we didn't find results, check if "All tests passed"
if [ ${#TEST_STATUS[@]} -eq 0 ]; then
    if grep -q "All.*tests passed" "$LATEST_RUN" 2>/dev/null; then
        echo "✓ All tests passed (detected from summary)"
        ALL_PASSED=true
    else
        echo "⚠️  Could not determine test status, assuming failures"
        ALL_PASSED=false
    fi
else
    echo "✓ Parsed ${#TEST_STATUS[@]} test group results"
    ALL_PASSED=true
    for status in "${TEST_STATUS[@]}"; do
        if [ "$status" = "❌" ]; then
            ALL_PASSED=false
            break
        fi
    done
fi

# Helper function to get status for a group
get_status() {
    local group="$1"
    if [ ${#TEST_STATUS[@]} -eq 0 ]; then
        # No parsed results, use ALL_PASSED flag
        if [ "$ALL_PASSED" = true ]; then
            echo "✅"
        else
            echo "❌"
        fi
    else
        # Use parsed status or default to ❌ if not found
        echo "${TEST_STATUS[$group]:-❌}"
    fi
}

# Count totals
TOTAL_GROUPS=37
PASSED=0
FAILED=0

for group in connection_preface frame_format frame_size header_compression \
    stream_states stream_identifiers stream_concurrency stream_priority \
    stream_dependencies error_handling connection_errors extensions \
    data_frames headers_frames priority_frames rst_stream_frames \
    settings_frames push_promise_frames ping_frames goaway_frames \
    window_update_frames continuation_frames http_exchange \
    http_header_fields pseudo_headers connection_headers \
    request_pseudo_headers malformed_requests server_push push_requests \
    hpack_dynamic_table hpack_decoding hpack_table_management \
    hpack_integer hpack_string hpack_binary generic_tests; do

    status=$(get_status "$group")
    if [ "$status" = "✅" ]; then
        ((PASSED++))
    else
        ((FAILED++))
    fi
done

SUCCESS_RATE=$((PASSED * 100 / TOTAL_GROUPS))

echo "📈 Results: $PASSED passed, $FAILED failed ($SUCCESS_RATE% success rate)"

# Generate summary header
cat > "$OUTPUT_FILE" << EOF
# 🧪 HTTP/2 Compliance Test Results

## Summary

EOF

if [ "$FAILED" -eq 0 ]; then
    cat >> "$OUTPUT_FILE" << EOF
### ✅ All Tests Passed!

- **Total Groups**: 37
- **Individual Tests**: 156
- **Success Rate**: 100%
- **Status**: 🎉 Complete RFC 7540 & RFC 7541 Compliance

EOF
else
    cat >> "$OUTPUT_FILE" << EOF
### ⚠️ Some Tests Failed

- **Passed**: $PASSED / $TOTAL_GROUPS groups
- **Failed**: $FAILED / $TOTAL_GROUPS groups
- **Success Rate**: ${SUCCESS_RATE}%

EOF
fi

# Generate detailed tables with actual status
cat >> "$OUTPUT_FILE" << EOF
## Test Coverage by RFC Section

### RFC 7540 - HTTP/2 Protocol

<details open>
<summary><b>Core Protocol</b></summary>

| Test ID | Description | RFC Section | Status |
|---------|-------------|-------------|--------|
| 3.5/1 | Valid connection preface | §3.5 | $(get_status "connection_preface") |
| 3.5/2 | Invalid connection preface | §3.5 | $(get_status "connection_preface") |
| 4.1/1 | Unknown frame type | §4.1 | $(get_status "frame_format") |
| 4.1/2 | PING with undefined flags | §4.1 | $(get_status "frame_format") |
| 4.1/3 | PING with reserved bit | §4.1 | $(get_status "frame_format") |
| 4.2/1 | DATA frame 2^14 octets | §4.2 | $(get_status "frame_size") |
| 4.2/2 | Oversized DATA frame | §4.2 | $(get_status "frame_size") |
| 4.2/3 | Oversized HEADERS frame | §4.2 | $(get_status "frame_size") |
| 4.3/1 | Invalid header block fragment | §4.3 | $(get_status "header_compression") |
| 4.3/2 | Header block after END_HEADERS | §4.3 | $(get_status "header_compression") |

</details>

<details open>
<summary><b>Stream Management</b></summary>

| Test ID | Description | RFC Section | Status |
|---------|-------------|-------------|--------|
| 5.1/1-17 | Stream states (17 tests) | §5.1 | $(get_status "stream_states") |
| 5.1.1/1-4 | Stream identifiers (4 tests) | §5.1.1 | $(get_status "stream_identifiers") |
| 5.1.2/1-2 | Stream concurrency (2 tests) | §5.1.2 | $(get_status "stream_concurrency") |
| 5.3/1-2 | Stream priority (2 tests) | §5.3 | $(get_status "stream_priority") |
| 5.3.1/1-3 | Stream dependencies (3 tests) | §5.3.1 | $(get_status "stream_dependencies") |
| 5.4/1-4 | Error handling (4 tests) | §5.4 | $(get_status "error_handling") |
| 5.4.1/1-3 | Connection errors (3 tests) | §5.4.1 | $(get_status "connection_errors") |
| 5.5/1-2 | Extensions (2 tests) | §5.5 | $(get_status "extensions") |

</details>

<details open>
<summary><b>Frame Definitions</b></summary>

| Test ID | Description | RFC Section | Status |
|---------|-------------|-------------|--------|
| 6.1/1-6 | DATA frames (6 tests) | §6.1 | $(get_status "data_frames") |
| 6.2/1-6 | HEADERS frames (6 tests) | §6.2 | $(get_status "headers_frames") |
| 6.3/1-4 | PRIORITY frames (4 tests) | §6.3 | $(get_status "priority_frames") |
| 6.4/1-4 | RST_STREAM frames (4 tests) | §6.4 | $(get_status "rst_stream_frames") |
| 6.5/1-10 | SETTINGS frames (10 tests) | §6.5 | $(get_status "settings_frames") |
| 6.6/1-4 | PUSH_PROMISE frames (4 tests) | §6.6 | $(get_status "push_promise_frames") |
| 6.7/1-4 | PING frames (4 tests) | §6.7 | $(get_status "ping_frames") |
| 6.8/1-4 | GOAWAY frames (4 tests) | §6.8 | $(get_status "goaway_frames") |
| 6.9/1-5 | WINDOW_UPDATE frames (5 tests) | §6.9 | $(get_status "window_update_frames") |
| 6.10/1-4 | CONTINUATION frames (4 tests) | §6.10 | $(get_status "continuation_frames") |

</details>

<details open>
<summary><b>HTTP Semantics</b></summary>

| Test ID | Description | RFC Section | Status |
|---------|-------------|-------------|--------|
| 8.1/1-5 | HTTP request/response (5 tests) | §8.1 | $(get_status "http_exchange") |
| 8.1.2/1-6 | HTTP header fields (6 tests) | §8.1.2 | $(get_status "http_header_fields") |
| 8.1.2.1/1-2 | Pseudo-header fields (2 tests) | §8.1.2.1 | $(get_status "pseudo_headers") |
| 8.1.2.2/1-5 | Connection headers (5 tests) | §8.1.2.2 | $(get_status "connection_headers") |
| 8.1.2.3/1-3 | Request pseudo-headers (3 tests) | §8.1.2.3 | $(get_status "request_pseudo_headers") |
| 8.1.2.6/1-2 | Malformed requests (2 tests) | §8.1.2.6 | $(get_status "malformed_requests") |
| 8.2/1-2 | Server push (2 tests) | §8.2 | $(get_status "server_push") |
| 8.2.1/1-2 | Push requests (2 tests) | §8.2.1 | $(get_status "push_requests") |

</details>

### RFC 7541 - HPACK Compression

<details open>
<summary><b>HPACK Tests</b></summary>

| Test ID | Description | RFC Section | Status |
|---------|-------------|-------------|--------|
| hpack/2.3.2/1-3 | Dynamic table (3 tests) | §2.3.2 | $(get_status "hpack_dynamic_table") |
| hpack/3.2/1-3 | Header block decoding (3 tests) | §3.2 | $(get_status "hpack_decoding") |
| hpack/4/1-3 | Table management (3 tests) | §4 | $(get_status "hpack_table_management") |
| hpack/5.1/1-2 | Integer encoding (2 tests) | §5.1 | $(get_status "hpack_integer") |
| hpack/5.2/1-3 | String encoding (3 tests) | §5.2 | $(get_status "hpack_string") |
| hpack/6/1-2 | Binary format (2 tests) | §6 | $(get_status "hpack_binary") |

</details>

### Generic Protocol Tests

<details open>
<summary><b>Additional Coverage</b></summary>

| Test ID | Description | Status |
|---------|-------------|--------|
| generic/1-15 | Connection lifecycle (15 tests) | $(get_status "generic_tests") |

</details>

## Test Groups Summary

| Group | Tests | Status |
|-------|-------|--------|
| Connection Preface | 2 | $(get_status "connection_preface") |
| Frame Format | 3 | $(get_status "frame_format") |
| Frame Size | 3 | $(get_status "frame_size") |
| Header Compression | 2 | $(get_status "header_compression") |
| Stream States | 17 | $(get_status "stream_states") |
| Stream Identifiers | 4 | $(get_status "stream_identifiers") |
| Stream Concurrency | 2 | $(get_status "stream_concurrency") |
| Stream Priority | 2 | $(get_status "stream_priority") |
| Stream Dependencies | 3 | $(get_status "stream_dependencies") |
| Error Handling | 4 | $(get_status "error_handling") |
| Connection Errors | 3 | $(get_status "connection_errors") |
| Extensions | 2 | $(get_status "extensions") |
| DATA Frames | 6 | $(get_status "data_frames") |
| HEADERS Frames | 6 | $(get_status "headers_frames") |
| PRIORITY Frames | 4 | $(get_status "priority_frames") |
| RST_STREAM Frames | 4 | $(get_status "rst_stream_frames") |
| SETTINGS Frames | 10 | $(get_status "settings_frames") |
| PUSH_PROMISE Frames | 4 | $(get_status "push_promise_frames") |
| PING Frames | 4 | $(get_status "ping_frames") |
| GOAWAY Frames | 4 | $(get_status "goaway_frames") |
| WINDOW_UPDATE Frames | 5 | $(get_status "window_update_frames") |
| CONTINUATION Frames | 4 | $(get_status "continuation_frames") |
| HTTP Exchange | 5 | $(get_status "http_exchange") |
| HTTP Header Fields | 6 | $(get_status "http_header_fields") |
| Pseudo Headers | 2 | $(get_status "pseudo_headers") |
| Connection Headers | 5 | $(get_status "connection_headers") |
| Request Pseudo Headers | 3 | $(get_status "request_pseudo_headers") |
| Malformed Requests | 2 | $(get_status "malformed_requests") |
| Server Push | 2 | $(get_status "server_push") |
| Push Requests | 2 | $(get_status "push_requests") |
| HPACK Dynamic Table | 3 | $(get_status "hpack_dynamic_table") |
| HPACK Decoding | 3 | $(get_status "hpack_decoding") |
| HPACK Table Management | 3 | $(get_status "hpack_table_management") |
| HPACK Integer | 2 | $(get_status "hpack_integer") |
| HPACK String | 3 | $(get_status "hpack_string") |
| HPACK Binary | 2 | $(get_status "hpack_binary") |
| Generic Tests | 15 | $(get_status "generic_tests") |

---

## 📊 Statistics

- **Total Test Groups**: 37
- **Passed**: $PASSED
- **Failed**: $FAILED
- **Success Rate**: ${SUCCESS_RATE}%
- **Total Individual Tests**: 156
- **RFC 7540 Coverage**: $([ "$FAILED" -eq 0 ] && echo "Complete" || echo "Partial")
- **RFC 7541 Coverage**: $([ "$FAILED" -eq 0 ] && echo "Complete" || echo "Partial")

## 📝 Documentation

- [Full Coverage Guide](docs/H2_COMPLIANCE_FULL_COVERAGE.md)
- [Test Results](docs/H2_COMPLIANCE_TEST_RESULTS.md)
- [Setup Instructions](docs/H2_COMPLIANCE_SETUP.md)

EOF

echo "✓ Summary generated: $OUTPUT_FILE"
echo "  Passed: $PASSED/$TOTAL_GROUPS"
echo "  Failed: $FAILED/$TOTAL_GROUPS"
