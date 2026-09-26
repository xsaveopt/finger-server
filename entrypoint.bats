#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
    export WORK_DIR="$BATS_TEST_DIRNAME/.tmp/entrypoint-test"
    export STUB_DIR="$WORK_DIR/stub"
    export ENTRYPOINT="$BATS_TEST_DIRNAME/entrypoint.sh"

    if ! command -v jq >/dev/null 2>&1; then
        skip "jq is needed to run these tests"
    fi

    local candidate resolved
    for candidate in ${BASH_BIN:-} bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
        resolved=$(command -v "$candidate" 2>/dev/null) || continue
        if "$resolved" -c 'readarray -t probe < /dev/null' 2>/dev/null; then
            export BASH_CMD="$resolved"
            break
        fi
    done

    if [ -z "${BASH_CMD:-}" ]; then
        skip "these tests need a bash with readarray, point BASH_BIN at one"
    fi

    rm -rf "$WORK_DIR"
    mkdir -p "$STUB_DIR"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"${CHOWN_LOG:-/dev/null}"\nexit 0\n' >"$STUB_DIR/chown"
    chmod 755 "$STUB_DIR/chown"
}

teardown_file() {
    if [ -n "${WORK_DIR:-}" ]; then
        rm -rf "$WORK_DIR"
    fi
}

setup() {
    CASE_DIR="$WORK_DIR/$BATS_TEST_NAME"
    HOMES="$CASE_DIR/home"
    export CHOWN_LOG="$CASE_DIR/chown.log"
    rm -rf "$CASE_DIR"
    mkdir -p "$HOMES"
}

teardown() {
    if [ -n "${CASE_DIR:-}" ]; then
        rm -rf "$CASE_DIR"
    fi
}

users_file() {
    printf '%s\n' "$1" >"$CASE_DIR/users.json"
}

run_entrypoint() {
    run --separate-stderr env \
        PATH="$STUB_DIR:$PATH" \
        USERS_FILE="$CASE_DIR/users.json" \
        PASSWD_FILE="${1:-$CASE_DIR/passwd}" \
        HOME_ROOT="$HOMES" \
        PROVISION_ONLY=1 \
        "$BASH_CMD" "$ENTRYPOINT"
}

@test "an unsupported key stops provisioning" {
    users_file '{"users":[{"username":"alice","nickname":"al"}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: unsupported keys: nickname"* ]] || return 1
}

@test "a non-string field stops provisioning" {
    users_file '{"users":[{"username":"alice","gecos":42,"shell":false}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: gecos must be a string"* ]] || return 1
    [[ "$stderr" == *"Entry 1: shell must be a string"* ]] || return 1
}

@test "an entry without a username stops provisioning" {
    users_file '{"users":[{"gecos":"Alice"}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: missing username"* ]] || return 1
}

@test "an empty username stops provisioning" {
    users_file '{"users":[{"username":""}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: username must be non-empty"* ]] || return 1
}

@test "a numeric username stops provisioning" {
    users_file '{"users":[{"username":42}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: username must be a string"* ]] || return 1
}

@test "a username outside the allowed characters stops provisioning" {
    users_file '{"users":[{"username":"1 bad"}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: username contains invalid characters"* ]] || return 1
}

@test "an entry that is not an object stops provisioning" {
    users_file '{"users":[{"username":"alice"},"bob"]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 2: expected object"* ]] || return 1
}

@test "a users field that is not an array stops provisioning" {
    users_file '{"users":"alice"}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Field users must be an array"* ]] || return 1
}

@test "a top-level scalar stops provisioning" {
    users_file '"alice"'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Expected top-level array or object with users array"* ]] || return 1
}

@test "an object with no users key exits cleanly" {
    users_file '{"other":1}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [[ "$stderr" == *"nothing to do"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
}

@test "an empty users array exits cleanly" {
    users_file '{"users":[]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
}

@test "a bare array is provisioned" {
    users_file '[{"username":"alice","gecos":"Alice","shell":"/bin/sh","home":"empty"}]'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
}

@test "a bare array and a users object give the same passwd" {
    users_file '[{"username":"alice","gecos":"Alice","shell":"/bin/sh","home":"empty"}]'
    run_entrypoint "$CASE_DIR/passwd-bare"
    [ "$status" -eq 0 ] || return 1

    users_file '{"users":[{"username":"alice","gecos":"Alice","shell":"/bin/sh","home":"empty"}]}'
    run_entrypoint "$CASE_DIR/passwd-object"
    [ "$status" -eq 0 ] || return 1

    cmp "$CASE_DIR/passwd-bare" "$CASE_DIR/passwd-object"
}

@test "the literal home empty is provisioned" {
    users_file '{"users":[{"username":"root","gecos":"Root","shell":"/bin/sh","home":"empty","plan":"hidden"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n' 'root:*:0:0:Root::/bin/sh' >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
    [ ! -e "$HOMES/root" ] || return 1
    [ ! -e "$CASE_DIR/empty" ] || return 1
}

@test "entries without a home are provisioned" {
    users_file '{"users":[{"username":"alice","gecos":"Alice","shell":"/bin/sh","plan":"gone fishing"},{"username":"carol","home":""}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n' "alice:*:0:0:Alice:$HOMES/alice:/bin/sh
carol:*:1:1::$HOMES/carol:" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
    [ -f "$HOMES/alice/.plan" ] || return 1
    [ "$(cat "$HOMES/alice/.plan")" = "gone fishing" ] || return 1
    [ ! -e "$HOMES/carol/.plan" ] || return 1
}

@test "a custom home is provisioned" {
    users_file "$(printf '{"users":[{"username":"bob","gecos":"Bob","shell":"/bin/sh","home":"%s/elsewhere/bob","plan":"never written"}]}' "$CASE_DIR")"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n' "bob:*:0:0:Bob:$CASE_DIR/elsewhere/bob:/bin/sh" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
    [ ! -e "$CASE_DIR/elsewhere" ] || return 1
    [ ! -e "$HOMES/bob" ] || return 1
}

@test "an entry without a shell is provisioned" {
    users_file '{"users":[{"username":"dave","home":"empty"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n' 'dave:*:0:0:::' >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
}

@test "missing home dirs are created and handed to their user" {
    rm -rf "$HOMES"
    users_file "$(printf '{"users":[{"username":"alice"},{"username":"bob","home":"%s/bob"}]}' "$HOMES")"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ -d "$HOMES/alice" ] || return 1
    [ -d "$HOMES/bob" ] || return 1
    printf '%s\n' "alice $HOMES/alice" "bob $HOMES/bob" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CHOWN_LOG"
}

@test "an existing home dir is kept and not chowned" {
    mkdir -p "$HOMES/alice"
    printf 'keep\n' >"$HOMES/alice/notes"
    users_file '{"users":[{"username":"alice","plan":"still here"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ ! -e "$CHOWN_LOG" ] || return 1
    [ "$(cat "$HOMES/alice/notes")" = "keep" ] || return 1
    [ "$(cat "$HOMES/alice/.plan")" = "still here" ] || return 1
}

@test "a plan is written verbatim with a trailing newline" {
    users_file '{"users":[{"username":"alice","plan":"first line\n  indented 100% done\\n $(id) `id` $HOME\n"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' 'first line' '  indented 100% done\n $(id) `id` $HOME' >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$HOMES/alice/.plan"
}

@test "a plan replaces an existing plan file" {
    mkdir -p "$HOMES/alice"
    printf 'old plan\nwith a second line\n' >"$HOMES/alice/.plan"
    users_file '{"users":[{"username":"alice","plan":"new plan"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' 'new plan' >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$HOMES/alice/.plan"
}

@test "an empty plan creates the home but no plan file" {
    users_file '{"users":[{"username":"alice","plan":""}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ -d "$HOMES/alice" ] || return 1
    [ ! -e "$HOMES/alice/.plan" ] || return 1
    printf '%s\n' "alice $HOMES/alice" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CHOWN_LOG"
}

@test "each user gets their own plan" {
    users_file '{"users":[{"username":"alice","plan":"alice plan"},{"username":"bob"},{"username":"carol","plan":"carol plan"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ "$(cat "$HOMES/alice/.plan")" = "alice plan" ] || return 1
    [ -d "$HOMES/bob" ] || return 1
    [ ! -e "$HOMES/bob/.plan" ] || return 1
    [ "$(cat "$HOMES/carol/.plan")" = "carol plan" ] || return 1
}

@test "a missing users file exits cleanly" {
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [[ "$stderr" == *"No users defined"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
}

@test "an empty users file exits cleanly" {
    : >"$CASE_DIR/users.json"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [[ "$stderr" == *"No users defined"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
}

@test "invalid JSON stops provisioning" {
    users_file '{"users":[{"username":"alice"'
    run_entrypoint

    [ "$status" -ne 0 ] || return 1
    [ -n "$stderr" ] || return 1
    [[ "$stderr" != *"nothing to do"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
    [ ! -e "$HOMES/alice" ] || return 1
}

@test "a non-string home or plan stops provisioning" {
    users_file '{"users":[{"username":"alice","home":5,"plan":["gone fishing"]}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: home must be a string"* ]] || return 1
    [[ "$stderr" == *"Entry 1: plan must be a string"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
}

@test "errors from every entry are reported together" {
    users_file '{"users":[{"username":"alice","nickname":"al","gecos":1},{"username":"bob"},{"gecos":"no name"},{"username":"carol","home":1}]}'
    run_entrypoint

    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"Entry 1: unsupported keys: nickname"* ]] || return 1
    [[ "$stderr" == *"Entry 1: gecos must be a string"* ]] || return 1
    [[ "$stderr" != *"Entry 2"* ]] || return 1
    [[ "$stderr" == *"Entry 3: missing username"* ]] || return 1
    [[ "$stderr" == *"Entry 4: home must be a string"* ]] || return 1
    [ ! -e "$CASE_DIR/passwd" ] || return 1
    [ ! -e "$HOMES/bob" ] || return 1
}

@test "a custom home that starts with the default home is not given a plan" {
    users_file "$(printf '{"users":[{"username":"al","home":"%s/alfred","plan":"not shown"}]}' "$HOMES")"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n' "al:*:0:0::$HOMES/alfred:" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
    [ ! -e "$HOMES/alfred" ] || return 1
    [ ! -e "$CHOWN_LOG" ] || return 1
}

@test "a custom home with a longer name than the default is not given a plan" {
    users_file "$(printf '{"users":[{"username":"alice","home":"%s/alice2","plan":"not shown"}]}' "$HOMES")"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ ! -e "$HOMES/alice2" ] || return 1
    [ ! -e "$CHOWN_LOG" ] || return 1
}

@test "a duplicate username does not give the second entry's custom home a plan" {
    users_file "$(printf '{"users":[{"username":"alice","plan":"first plan"},{"username":"alice","home":"%s/elsewhere/alice","plan":"second plan"}]}' "$CASE_DIR")"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ "$(cat "$HOMES/alice/.plan")" = "first plan" ] || return 1
    [ ! -e "$CASE_DIR/elsewhere" ] || return 1
    printf '%s\n' "alice $HOMES/alice" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CHOWN_LOG"
}

@test "a home root with regex characters is matched literally" {
    HOMES="$CASE_DIR/home+root"
    mkdir -p "$HOMES"
    users_file '{"users":[{"username":"alice","plan":"gone fishing"}]}'
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    [ -d "$HOMES/alice" ] || return 1
    [ "$(cat "$HOMES/alice/.plan")" = "gone fishing" ] || return 1
}

@test "the shipped sample users file is provisioned" {
    cp "$BATS_TEST_DIRNAME/users.json" "$CASE_DIR/users.json"
    run_entrypoint

    [ "$status" -eq 0 ] || return 1
    printf '\n%s\n%s\n%s\n' 'root:*:0:0:::' 'user:*:1:1:User Name:a house:cool shell' "user2:*:2:2:firstname lastname:$HOMES/user2:less cool shell" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CASE_DIR/passwd"
    [ ! -e "$HOMES/root" ] || return 1
    [ ! -e "$HOMES/user" ] || return 1
    [ "$(cat "$HOMES/user2/.plan")" = "a working plan file" ] || return 1
    printf '%s\n' "user2 $HOMES/user2" >"$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CHOWN_LOG"
}
