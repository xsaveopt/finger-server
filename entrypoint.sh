#!/usr/bin/env bash
set -euo pipefail

# provision local users from json definitions.
USERS_FILE="/users.json"
if [ ! -s "$USERS_FILE" ]; then
    echo "No users defined in $USERS_FILE; skipping provisioning." >&2
    exit 0
fi

# detect nologin shell
NOLOGIN_SHELL=$(command -v nologin 2>/dev/null || true)
if [ -z "$NOLOGIN_SHELL" ]; then
    for candidate in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [ -x "$candidate" ]; then
            NOLOGIN_SHELL="$candidate"
            break
        fi
    done
fi

# populate users array from json
readarray -t USERS < <(jq -c 'if type == "array" then . else (.users // []) end | .[]' "$USERS_FILE")
if [ ${#USERS[@]} -eq 0 ]; then
    echo "No user entries found in $USERS_FILE; nothing to do." >&2
    exit 0
fi

# initialize user and group numbers
UNUMBER=0
GNUMBER=0
echo "" > /etc/passwd

# process each user entry
for USER_JSON in "${USERS[@]}"; do
    # extract user fields
    USERNAME_FIELD=$(jq -r '.username // empty' <<<"$USER_JSON")
    GECOS_FIELD=$(jq -r '.gecos // empty' <<<"$USER_JSON")
    SHELL_FIELD=$(jq -r '.shell // empty' <<<"$USER_JSON")
    HOME_FIELD=$(jq -r '.home // empty' <<<"$USER_JSON")

    # validate username
    if [ -z "$USERNAME_FIELD" ]; then
        echo "Skipping entry without a username." >&2
        continue
    fi

    # home dir
    HOME_DIR="${HOME_FIELD:-/home/$USERNAME_FIELD}"

    # leave home empty if explicitly set to "empty"
    if [ "$HOME_FIELD" == "empty" ]; then
        echo "$USERNAME_FIELD:*:$UNUMBER:$GNUMBER:$GECOS_FIELD::$SHELL_FIELD" >> /etc/passwd
    else
        echo "$USERNAME_FIELD:*:$UNUMBER:$GNUMBER:$GECOS_FIELD:$HOME_DIR:$SHELL_FIELD" >> /etc/passwd

        # set up home directory and files if no custom home specified
        if grep -qE "^$USERNAME_FIELD:.*:/home/$USERNAME_FIELD.*" /etc/passwd; then
            # ensure home directory exists
            if ! [ -d "$HOME_DIR" ]; then
                mkdir -p "$HOME_DIR"
                chown "$USERNAME_FIELD" "$HOME_DIR"
            fi

            # set up .plan file if provided
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

# move critical binary to root cause we remove /usr /sbin /bin
cp /usr/bin/fingerd /fingerd

# remove all ways of shelling in
rm -rf /entrypoint.sh || true
rm -rf /tmp || true
rm -rf /usr || true
rm -rf /sbin || true
rm -rf /lib/apk || true
rm -rf /bin || true

# start the main service
/fingerd -a 0.0.0.0