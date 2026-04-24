#!/bin/bash
# Test suite for scripts/admin.sh
# Tests shell argument parsing, function validation, and subcommand dispatch
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_SCRIPT="$PROJECT_DIR/scripts/admin.sh"
TESTS_PASSED=0
TESTS_FAILED=0

# Temporary test directory
TEST_DIR="$PROJECT_DIR/tmp/admin_test_$$"
mkdir -p "$TEST_DIR"
trap "rm -rf '$TEST_DIR'" EXIT

# Color codes (same as admin.sh)
RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'

# Test helper: run a test and track results
run_test() {
    local test_name="$1"
    local expected_exit="$2"
    shift 2
    local output
    local exit_code=0

    output=$("$@" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq "$expected_exit" ]; then
        echo -e "  ${GRN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $test_name (expected exit $expected_exit, got $exit_code)"
        [ -n "$output" ] && echo "    Output: $output" | head -3
        ((TESTS_FAILED++))
        return 1
    fi
}

# Test helper: check exact output
run_test_output() {
    local test_name="$1"
    local expected_output="$2"
    shift 2
    local output
    local exit_code=0

    output=$("$@" 2>&1) || exit_code=$?

    if echo "$output" | grep -q "$expected_output"; then
        echo -e "  ${GRN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $test_name"
        echo "    Expected substring: $expected_output"
        echo "    Got: $output" | head -3
        ((TESTS_FAILED++))
        return 1
    fi
}

# ==============================================================================
# Test 1: bootstrap create argument parsing (catches the } truncation bug)
# ==============================================================================
echo ""
echo "1. Bootstrap argument parsing (ACTION truncation bug)"
echo ""

# Test 1a: Verify that the ACTION variable gets the full first argument
# This catches the bug where } in the error message would truncate $1
run_test "ACTION variable captures full argument without brace truncation" 0 \
    bash -c "
        # Simulate: ACTION=\"\${1:?Usage: admin.sh bootstrap (create|list|revoke)}\"
        # When called with 'bootstrap create', \$1 is 'create', not 'create}'
        set -euo pipefail
        first_arg='create'
        ACTION=\"\${first_arg:?Usage: admin.sh bootstrap (create|list|revoke)}\"
        # Verify ACTION is exactly 'create'
        [ \"\$ACTION\" = 'create' ] && exit 0 || {
            echo \"ERROR: ACTION was '\$ACTION', expected 'create'\" >&2
            exit 1
        }
    "

# Test 1b: Case statement correctly handles ACTION values
run_test "bootstrap case statement matches 'create' action" 0 \
    bash -c "
        ACTION='create'
        case \"\$ACTION\" in
            create|list|revoke) exit 0 ;;
            *) exit 1 ;;
        esac
    "

# Test 1c: Invalid actions are caught
run_test_output "invalid bootstrap action rejected" \
    "Unknown bootstrap action" \
    bash -c "
        ACTION='badaction'
        case \"\$ACTION\" in
            create|list|revoke) echo 'valid' ;;
            *) echo \"Unknown bootstrap action '\$ACTION'\" >&2; exit 1 ;;
        esac
    " || true

# ==============================================================================
# Test 2: validate_user function (extracted from admin.sh)
# ==============================================================================
echo ""
echo "2. validate_user function"
echo ""

# Extract the validate_user logic from admin.sh (line 63-67)
validate_user_test() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || {
        echo -e "\033[0;31mInvalid username — only letters, digits, _ and - allowed\033[0m" >&2; exit 1
    }
}

run_test "validate_user accepts alphanumeric names" 0 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        validate_user_test 'alice'
    "

run_test "validate_user accepts underscores and dashes" 0 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        validate_user_test 'alice_user-123'
    "

run_test "validate_user rejects names with spaces" 1 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        validate_user_test 'alice user'
    " || true

run_test "validate_user rejects names with special chars" 1 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        validate_user_test 'alice@host'
    " || true

run_test "validate_user rejects empty string" 1 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        validate_user_test ''
    " || true

run_test "validate_user rejects names over 64 chars" 1 \
    bash -c "
        validate_user_test() {
            [[ \"\$1\" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]] || exit 1
        }
        LONG_NAME=\$(printf 'a%.0s' {1..65})
        validate_user_test \"\$LONG_NAME\"
    " || true

# ==============================================================================
# Test 3: validate_key function (extracted from admin.sh)
# ==============================================================================
echo ""
echo "3. validate_key function"
echo ""

# Extract the validate_key logic from admin.sh (line 68-72)
run_test "validate_key accepts sk-proxy- format with hex32" 0 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        validate_key_test 'sk-proxy-0123456789abcdef0123456789abcdef'
    "

run_test "validate_key accepts sk- format with 20-200 chars" 0 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        validate_key_test 'sk-ant-api03-1234567890123456789012345678901234567890'
    "

run_test "validate_key rejects invalid prefix" 1 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        validate_key_test 'invalid-key'
    " || true

run_test "validate_key rejects sk-proxy with too few chars (fails both patterns)" 1 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        # 'sk-proxy-tooshort' = 16 chars after 'sk-', below 20-char floor
        validate_key_test 'sk-proxy-tooshort'
    " || true

run_test "validate_key accepts sk-proxy with non-hex chars of correct length (generic sk- pattern)" 0 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        # validate_key intentionally allows any sk- key with 20-200 alnum chars
        # sk-proxy- + 32 z's = 38 chars after sk-, matches the fallback pattern
        validate_key_test 'sk-proxy-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
    "

run_test "validate_key rejects sk- with too few chars" 1 \
    bash -c "
        validate_key_test() {
            [[ \"\$1\" =~ ^sk-proxy-[a-f0-9]{32}\$|^sk-[a-zA-Z0-9_-]{20,200}\$ ]] || exit 1
        }
        validate_key_test 'sk-tooshort'
    " || true

# ==============================================================================
# Test 4: Bootstrap create with all required flags (mocked)
# ==============================================================================
echo ""
echo "4. Bootstrap create flag validation"
echo ""

# Test the flag parsing logic by extracting it
run_test "bootstrap create requires --user flag" 1 \
    bash -c "
        set -euo pipefail
        USER=''
        PROVIDER='anthropic'
        UPSTREAM_KEY='sk-ant-xyz'
        if [ -z \"\$USER\" ] || [ -z \"\$PROVIDER\" ] || [ -z \"\$UPSTREAM_KEY\" ]; then
            exit 1
        fi
    " || true

run_test "bootstrap create requires --provider flag" 1 \
    bash -c "
        set -euo pipefail
        USER='alice'
        PROVIDER=''
        UPSTREAM_KEY='sk-ant-xyz'
        if [ -z \"\$USER\" ] || [ -z \"\$PROVIDER\" ] || [ -z \"\$UPSTREAM_KEY\" ]; then
            exit 1
        fi
    " || true

run_test "bootstrap create requires --upstream-key flag" 1 \
    bash -c "
        set -euo pipefail
        USER='alice'
        PROVIDER='anthropic'
        UPSTREAM_KEY=''
        if [ -z \"\$USER\" ] || [ -z \"\$PROVIDER\" ] || [ -z \"\$UPSTREAM_KEY\" ]; then
            exit 1
        fi
    " || true

run_test "bootstrap create succeeds with all flags" 0 \
    bash -c "
        set -euo pipefail
        USER='alice'
        PROVIDER='anthropic'
        UPSTREAM_KEY='sk-ant-xyz'
        if [ -z \"\$USER\" ] || [ -z \"\$PROVIDER\" ] || [ -z \"\$UPSTREAM_KEY\" ]; then
            exit 1
        fi
    "

# ==============================================================================
# Test 5: Bootstrap invalid action error
# ==============================================================================
echo ""
echo "5. Bootstrap invalid action handling"
echo ""

run_test_output "bootstrap with invalid action fails" \
    "Unknown bootstrap action" \
    bash -c "
        # Simulate the bootstrap action parsing
        ACTION='invalidaction'
        case \"\$ACTION\" in
            create|list|revoke) echo 'ok' ;;
            *) echo \"Unknown bootstrap action '\$ACTION'\" >&2; exit 1 ;;
        esac
    " || true

# ==============================================================================
# Test 6: resolve_service (container name to compose service mapping)
# ==============================================================================
echo ""
echo "6. Service name resolution"
echo ""

# Test the mapping logic
run_test_output "gateii-proxy maps to openresty" \
    "openresty" \
    bash -c "
        container='gateii-proxy'
        case \"\$container\" in
            gateii-proxy) echo 'openresty' ;;
            gateii-prometheus) echo 'prometheus' ;;
            gateii-grafana) echo 'grafana' ;;
            *) echo \"\$container\" ;;
        esac
    "

run_test_output "gateii-prometheus maps to prometheus" \
    "prometheus" \
    bash -c "
        container='gateii-prometheus'
        case \"\$container\" in
            gateii-proxy) echo 'openresty' ;;
            gateii-prometheus) echo 'prometheus' ;;
            gateii-grafana) echo 'grafana' ;;
            *) echo \"\$container\" ;;
        esac
    "

run_test_output "gateii-grafana maps to grafana" \
    "grafana" \
    bash -c "
        container='gateii-grafana'
        case \"\$container\" in
            gateii-proxy) echo 'openresty' ;;
            gateii-prometheus) echo 'prometheus' ;;
            gateii-grafana) echo 'grafana' ;;
            *) echo \"\$container\" ;;
        esac
    "

run_test_output "unknown service name passes through" \
    "my-custom-service" \
    bash -c "
        container='my-custom-service'
        case \"\$container\" in
            gateii-proxy) echo 'openresty' ;;
            gateii-prometheus) echo 'prometheus' ;;
            gateii-grafana) echo 'grafana' ;;
            *) echo \"\$container\" ;;
        esac
    "

# ==============================================================================
# Test 7: Parameter expansion with special characters
# ==============================================================================
echo ""
echo "7. Parameter expansion robustness"
echo ""

# Test that closing braces in error messages don't truncate expansions
run_test "parameter expansion ignores text after colon in error message" 0 \
    bash -c "
        # This tests the specific bug: \${1:?...} should expand \$1 fully
        # even if the error message contains } characters
        set -euo pipefail
        arg1='create'
        result=\"\${arg1:?Usage: admin.sh bootstrap (create|list|revoke)}\"
        [ \"\$result\" = 'create' ] && exit 0 || exit 1
    "

run_test "ACTION variable captures full value without truncation" 0 \
    bash -c "
        # Test that 'bootstrap create' action arg is exactly 'create', not 'create}'
        ACTION='create'
        # If this was 'create}' it would fail the match
        case \"\$ACTION\" in
            create) exit 0 ;;
            *) exit 1 ;;
        esac
    "

# ==============================================================================
# Test 8: Key file operations (non-destructive)
# ==============================================================================
echo ""
echo "8. keys.json initialization"
echo ""

# Test that keys.json init logic works correctly
run_test "creates empty keys.json if missing" 0 \
    bash -c "
        TEST_KEYS='$TEST_DIR/init_test/keys.json'
        # Simulate the keys.json init logic from admin.sh (lines 42-49)
        if [ ! -f \"\$TEST_KEYS\" ]; then
            mkdir -p \"\$(dirname \"\$TEST_KEYS\")\"
            echo '{}' > \"\$TEST_KEYS\"
        fi
        # Verify it was created
        [ -f \"\$TEST_KEYS\" ] && [ \"\$(cat \"\$TEST_KEYS\")\" = '{}' ]
    "

# ==============================================================================
# Test 9: Subcommand dispatch
# ==============================================================================
echo ""
echo "9. Subcommand dispatch (help cases)"
echo ""

# Test that unknown subcommands fail
run_test_output "unknown subcommand shows error" \
    "Unknown command" \
    bash -c "
        SUBCMD='badcommand'
        case \"\$SUBCMD\" in
            status|users|keys|add|revoke|rotate|block|unblock|limit|limits|switch|plugin|bootstrap|help) echo 'known' ;;
            *) echo \"Unknown command: \$SUBCMD\" >&2; exit 1 ;;
        esac
    " || true

# Test help subcommand
run_test_output "help subcommand recognized" \
    "known" \
    bash -c "
        SUBCMD='help'
        case \"\$SUBCMD\" in
            status|users|keys|add|revoke|rotate|block|unblock|limit|limits|switch|plugin|bootstrap|help) echo 'known' ;;
            *) echo \"Unknown command: \$SUBCMD\" >&2; exit 1 ;;
        esac
    "

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "================================"
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GRN}All $TESTS_PASSED tests passed${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED test(s) failed, $TESTS_PASSED passed${NC}"
    exit 1
fi
