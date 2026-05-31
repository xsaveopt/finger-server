#!/usr/bin/env bash
set -euo pipefail

USERS_FILE="/users.json"
if [ ! -s "$USERS_FILE" ]; then
    echo "No users defined in $USERS_FILE; skipping provisioning." >&2
    exit 0
fi

VALIDATION_ERRORS=$(jq -r '
    def allowed_keys: ["username", "gecos", "shell", "home", "plan"];

    def ensure_string(idx; user; field):
        if user | has(field) then
            if (user[field] | type) == "string" then [] else ["Entry \(idx): \(field) must be a string"] end
        else
            []
        end;

    def ensure_known_keys(idx; user):
        (user | keys_unsorted - allowed_keys) as $unknown
        | if ($unknown | length) > 0 then ["Entry \(idx): unsupported keys: \($unknown | join(", "))"] else [] end;

    def collect_users:
        if type == "array" then {users: ., errors: []}
        elif type == "object" then
            if has("users") then
                if (.users | type) == "array" then {users: .users, errors: []}
                else {users: [], errors: ["Field users must be an array"]}
                end
            else
                {users: [], errors: []}
            end
        else
            {users: [], errors: ["Expected top-level array or object with users array"]}
        end;

    collect_users as $data
    | ($data.errors[])
    , ($data.users
            | to_entries[]
            | . as $entry
            | ($entry.key + 1) as $idx
            | (if ($entry.value | type) != "object" then
                        ["Entry \($idx): expected object"]
                else
                        ensure_known_keys($idx; $entry.value)
                        + (if ($entry.value | has("username") | not) then
                                    ["Entry \($idx): missing username"]
                            elif ($entry.value.username | type) != "string" then
                                    ["Entry \($idx): username must be a string"]
                            elif ($entry.value.username | length) == 0 then
                                    ["Entry \($idx): username must be non-empty"]
                            elif ($entry.value.username | test("^[A-Za-z_][A-Za-z0-9_-]*$")) then
                                    []
                            else
                                    ["Entry \($idx): username contains invalid characters"]
                            end)
                        + ensure_string($idx; $entry.value; "gecos")
                        + ensure_string($idx; $entry.value; "shell")
                        + ensure_string($idx; $entry.value; "home")
                        + ensure_string($idx; $entry.value; "plan")
                end)[]
        )
' "$USERS_FILE")

if [ -n "$VALIDATION_ERRORS" ]; then
    echo "Invalid entries in $USERS_FILE:" >&2
    echo "$VALIDATION_ERRORS" >&2
    exit 1
fi

NOLOGIN_SHELL=$(command -v nologin 2>/dev/null || true)
if [ -z "$NOLOGIN_SHELL" ]; then
    for candidate in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [ -x "$candidate" ]; then
            NOLOGIN_SHELL="$candidate"
            break
        fi
    done
fi

readarray -t USERS < <(jq -c 'if type == "array" then . else (.users // []) end | .[]' "$USERS_FILE")
if [ ${#USERS[@]} -eq 0 ]; then
    echo "No user entries found in $USERS_FILE; nothing to do." >&2
    exit 0
fi

UNUMBER=0
GNUMBER=0
echo "" > /etc/passwd

for USER_JSON in "${USERS[@]}"; do
    USERNAME_FIELD=$(jq -r '.username // empty' <<<"$USER_JSON")
    GECOS_FIELD=$(jq -r '.gecos // empty' <<<"$USER_JSON")
    SHELL_FIELD=$(jq -r '.shell // empty' <<<"$USER_JSON")
    HOME_FIELD=$(jq -r '.home // empty' <<<"$USER_JSON")

    if [ -z "$USERNAME_FIELD" ]; then
        echo "Skipping entry without a username." >&2
        continue
    fi

    HOME_DIR="${HOME_FIELD:-/home/$USERNAME_FIELD}"

    if [ "$HOME_FIELD" == "empty" ]; then
        echo "$USERNAME_FIELD:*:$UNUMBER:$GNUMBER:$GECOS_FIELD::$SHELL_FIELD" >> /etc/passwd
    else
        echo "$USERNAME_FIELD:*:$UNUMBER:$GNUMBER:$GECOS_FIELD:$HOME_DIR:$SHELL_FIELD" >> /etc/passwd

        if grep -qE "^$USERNAME_FIELD:.*:/home/$USERNAME_FIELD.*" /etc/passwd; then
            if ! [ -d "$HOME_DIR" ]; then
                mkdir -p "$HOME_DIR"
                chown "$USERNAME_FIELD" "$HOME_DIR"
            fi

            PLAN_CONTENT=$(jq -r '.plan // empty' <<<"$USER_JSON")
            if [ -n "$PLAN_CONTENT" ]; then
                PLAN_FILE="$HOME_DIR/.plan"
                printf '%s\n' "$PLAN_CONTENT" >"$PLAN_FILE"
            fi
        fi
    fi

    UNUMBER=$((UNUMBER + 1))
    GNUMBER=$((GNUMBER + 1))
done

cat /etc/passwd

cp /usr/bin/fingerd /fingerd

rm -rf /entrypoint.sh || true
rm -rf /tmp || true
rm -rf /usr || true
rm -rf /sbin || true
rm -rf /lib/apk || true
rm -rf /bin || true

/fingerd -a 0.0.0.0