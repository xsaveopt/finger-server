#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
    if ! docker info >/dev/null 2>&1; then
        skip "docker is needed to run these tests"
    fi

    export IMAGE="finger-server:bats-smoke"
    export CLIENT_IMAGE="alpine:3"
    export CONTAINER_FILE="$BATS_FILE_TMPDIR/container"

    docker build -q -t "$IMAGE" "$BATS_TEST_DIRNAME" >/dev/null
    docker pull -q "$CLIENT_IMAGE" >/dev/null

    local id
    id=$(docker create "$IMAGE")
    printf '%s\n' "$id" >"$CONTAINER_FILE"
    docker cp "$BATS_TEST_DIRNAME/users.json" "$id:/users.json" >/dev/null
    docker start "$id" >/dev/null

    local attempt
    for attempt in $(seq 1 50); do
        if finger_query root | grep -q 'user: root'; then
            return 0
        fi
        sleep 0.2
    done
    docker logs "$id" >&2
    return 1
}

teardown_file() {
    if [ -f "${CONTAINER_FILE:-}" ]; then
        docker rm -f "$(cat "$CONTAINER_FILE")" >/dev/null 2>&1 || true
    fi
    if [ -n "${IMAGE:-}" ]; then
        docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    fi
}

container_id() {
    cat "$CONTAINER_FILE"
}

finger_query() {
    docker run --rm --network "container:$(cat "$CONTAINER_FILE")" "$CLIENT_IMAGE" \
        sh -c 'printf "%s\r\n" "$1" | timeout 5 nc 127.0.0.1 79 | head -c "${2:-4096}"' sh "$1" "${2:-4096}"
}

@test "the container keeps running with the sample users" {
    [ "$(docker inspect -f '{{.State.Running}}' "$(container_id)")" = "true" ] || return 1
}

@test "the container prints the provisioned accounts" {
    run docker logs "$(container_id)"

    [[ "$output" == *"user2:*:2:2:firstname lastname:/home/user2:less cool shell"* ]] || return 1
}

@test "the container drops its tools before serving" {
    local listing
    listing=$(docker export "$(container_id)" | tar -t)

    grep -qx 'fingerd' <<<"$listing" || return 1
    ! grep -qE '^(usr|bin|sbin|tmp|lib/apk)/' <<<"$listing" || return 1
    ! grep -qx 'entrypoint.sh' <<<"$listing" || return 1
}

@test "a lookup answers with the user's details and plan" {
    run finger_query user2

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"user: user2"* ]] || return 1
    [[ "$output" == *"name: firstname lastname"* ]] || return 1
    [[ "$output" == *"dir: /home/user2"* ]] || return 1
    [[ "$output" == *"shell: less cool shell"* ]] || return 1
    [[ "$output" == *"a working plan file"* ]] || return 1
}

@test "a lookup response ends after the plan" {
    local bytes
    bytes=$(finger_query user2 65536 | wc -c)

    [ "$bytes" -gt 0 ] || return 1
    [ "$bytes" -lt 1024 ] || return 1
}

@test "a lookup of an unknown user says so" {
    run finger_query nosuchuser

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"nosuchuser"* ]] || return 1
    [[ "$output" != *"plan:"* ]] || return 1
}

@test "the container exits cleanly without a users file" {
    run --separate-stderr docker run --rm "$IMAGE"

    [ "$status" -eq 0 ] || return 1
    [[ "$stderr" == *"No users defined"* ]] || return 1
}
