#!/bin/sh
# Read asdf .tool-versions and print defaults and JSON lanes as GitHub outputs.
# Run --self-test for the portable validation cases. This single file is shared
# across repositories and runs before any listed toolchain is installed.

self_test() (
    scratch=$(mktemp -d) || exit 1
    trap 'rm -rf "$scratch"' 0
    trap 'exit 1' HUP INT TERM
    passed=0
    failed=0

    check() {
        label=$1
        expected_status=$2
        expected=$3
        shift 3
        actual=$(sh "$0" "$@" 2>&1)
        status=$?
        if { [ "$expected_status" = good ] && [ "$status" -eq 0 ]; } ||
           { [ "$expected_status" = bad ] && [ "$status" -ne 0 ]; }; then
            if [ "$actual" = "$expected" ]; then
                printf 'ok: %s\n' "$label"
                passed=$((passed + 1))
                return
            fi
        fi
        printf 'FAIL: %s (status %s)\n' "$label" "$status"
        failed=$((failed + 1))
    }

    good() {
        printf '%s\n' "$2" > "$scratch/.tool-versions"
        check "$1" good "$3" "$scratch/.tool-versions"
    }

    bad() {
        printf '%s\n' "$2" > "$scratch/.tool-versions"
        check "$1" bad "toolchain: $3" "$scratch/.tool-versions"
    }

    good 'BEAM and Node' 'elixir 1.20.3-otp-29 1.20.4-otp-28 1.19.6-otp-28
erlang 29.0.3 28.5
nodejs 24.19.0 26.13.0' 'elixir=1.20.3-otp-29
elixir_lanes=["1.20.4-otp-28","1.19.6-otp-28"]
erlang=29.0.3
erlang_lanes=["28.5"]
nodejs=24.19.0
nodejs_lanes=["26.13.0"]
beam_lanes=[{"elixir":"1.20.4-otp-28","otp":"28.5"},{"elixir":"1.19.6-otp-28","otp":"28.5"}]
otp=29.0.3'
    good 'Go only' 'golang 1.27.4 1.26.9' 'golang=1.27.4
golang_lanes=["1.26.9"]'
    good 'Erlang only' 'erlang 29.0.3 28.5' 'erlang=29.0.3
erlang_lanes=["28.5"]'
    good 'Elixir only' 'elixir 1.20.3' 'elixir=1.20.3
elixir_lanes=[]'
    good 'comments, blanks and CRLF' "$(printf '# tools\n\n  python 3.15.0 3.14.2 # lanes\r\n\tgolang 1.27.4\n')" 'python=3.15.0
python_lanes=["3.14.2"]
golang=1.27.4
golang_lanes=[]'
    good 'empty file' '' ''
    good 'JSON escaping' 'python system path:a\b"c' 'python=system
python_lanes=["path:a\\b\"c"]'
    check 'missing file' bad 'toolchain: cannot read file' "$scratch/missing"
    check 'unreadable file' bad 'toolchain: cannot read file' "$scratch"
    bad 'missing version' 'python # missing' 'no version for python'
    bad 'duplicate tool' 'python 3.15.0
python 3.14.2' 'duplicate tool python'
    bad 'invalid tool name' 'bad-name 1.0' 'invalid tool name bad-name'
    bad 'missing OTP suffix' 'elixir 1.20.3
erlang 29.0.3' 'Elixir 1.20.3 has no -otp-NN suffix'
    bad 'missing OTP major' 'elixir 1.20.3-otp-29 1.20.4-otp-28
erlang 29.0.3' 'no Erlang version for Elixir OTP 28'
    bad 'ambiguous OTP major' 'elixir 1.20.3-otp-29
erlang 29.0.3 29.0.2' 'multiple Erlang versions for Elixir OTP 29'
    bad 'orphan Erlang' 'elixir 1.20.3-otp-29
erlang 29.0.3 28.5' 'Erlang 28.5 is paired by no Elixir version'
    bad 'default OTP mismatch' 'elixir 1.20.3-otp-29 1.20.4-otp-28
erlang 28.5 29.0.3' 'default Elixir OTP does not match default Erlang'

    if [ "$failed" -ne 0 ]; then
        printf 'toolchain self-test: %s cases failed\n' "$failed"
        exit 1
    fi
    printf 'toolchain self-test: %s cases passed\n' "$passed"
)

if [ "${1-}" = --self-test ]; then
    self_test
    exit $?
fi

file=${1-.tool-versions}
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf '%s\n' 'toolchain: cannot read file' >&2
    exit 1
fi

if output=$(awk '
function fail(message) {
    print "toolchain: " message
    failed = 1
    exit 1
}
function quote(value,    result, i, c) {
    result = "\""
    for (i = 1; i <= length(value); i++) {
        c = substr(value, i, 1)
        if (c == "\\" || c == "\"") result = result "\\"
        result = result c
    }
    return result "\""
}
{
    sub(/\r$/, "")
    sub(/#.*/, "")
    if (NF == 0) next
    tool = $1
    if (tool !~ /^[a-z0-9_]+$/) fail("invalid tool name " tool)
    if (tool in count) fail("duplicate tool " tool)
    if (NF < 2) fail("no version for " tool)
    tools[++total] = tool
    count[tool] = NF - 1
    for (i = 2; i <= NF; i++) versions[tool, i - 1] = $i
}
END {
    if (failed) exit 1
    beam = ("elixir" in count && "erlang" in count)
    if (beam) {
        for (i = 1; i <= count["elixir"]; i++) {
            build = versions["elixir", i]
            if (build !~ /-otp-[0-9]+$/) fail("Elixir " build " has no -otp-NN suffix")
            major = build
            sub(/^.*-otp-/, "", major)
            matches = 0
            for (j = 1; j <= count["erlang"]; j++) {
                otp = versions["erlang", j]
                sub(/\..*$/, "", otp)
                if (otp == major) {
                    matches++
                    paired[i] = versions["erlang", j]
                    used[j] = 1
                }
            }
            if (matches == 0) fail("no Erlang version for Elixir OTP " major)
            if (matches > 1) fail("multiple Erlang versions for Elixir OTP " major)
        }
        for (j = 1; j <= count["erlang"]; j++)
            if (!(j in used)) fail("Erlang " versions["erlang", j] " is paired by no Elixir version")
        if (paired[1] != versions["erlang", 1]) fail("default Elixir OTP does not match default Erlang")
    }
    for (t = 1; t <= total; t++) {
        tool = tools[t]
        print tool "=" versions[tool, 1]
        lanes = ""
        for (i = 2; i <= count[tool]; i++)
            lanes = lanes (i > 2 ? "," : "") quote(versions[tool, i])
        print tool "_lanes=[" lanes "]"
    }
    if (beam) {
        lanes = ""
        for (i = 2; i <= count["elixir"]; i++)
            lanes = lanes (i > 2 ? "," : "") "{\"elixir\":" quote(versions["elixir", i]) ",\"otp\":" quote(paired[i]) "}"
        print "beam_lanes=[" lanes "]"
        print "otp=" versions["erlang", 1]
    }
}
' < "$file"); then
    if [ -n "$output" ]; then printf '%s\n' "$output"; fi
else
    printf '%s\n' "$output" >&2
    exit 1
fi
