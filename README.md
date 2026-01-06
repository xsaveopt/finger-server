## Finger Server

Minimal finger service that responds with mock finger lookup results sourced from a runtime-provided JSON file.

### users.json layout
- Build-time usage is optional; the image only requires the file at runtime.
- Required top-level key: `users`, an array of user records.
- A record supports the following fields:
    - `username`: unique identifier exposed in lookups.
    - `gecos`: optional finger display name.
    - `shell`: optional string describing the preferred shell.
    - `home`: optional home-directory display value. See behavior rules below.
    - `plan`: optional multi-line string rendered when allowed.
- `home` and `plan` interaction rules:
    - When `home` has a non-empty string (other than the literal `empty`), the plan text is suppressed.
    - When `home` is empty (`""`), the plan text is shown in the response.
    - When `home` equals the literal `"empty"`, the home is hidden in the response and the plan remains hidden as well.

Example:
```
{
    "users": [
        {
            "username": "jdoe",
            "gecos": "Jane Doe",
            "shell": "bash",
            "home": "",
            "plan": "Finish onboarding\nUpdate keys"
        }
    ]
}
```

### Build the container image
1. Ensure the Dockerfile and application sources are present.
2. Build the image: `docker build -t finger-server:latest .`

### Run requirements
- The container expects `users.json` at `/users.json` when it starts. Mount it explicitly:
    - `docker run --rm -p 79:79 -v "$PWD/users.json":/users.json:ro finger-server:latest`
- Without the volume, the entrypoint exits immediately.

### Runtime hardening
- The process starts as root, but the entrypoint immediately prunes all interactive shells, reducing the attack surface even if a shell binary is present.
- For additional isolation, enable Docker user remapping (`--userns-remap`) so host users map to non-root IDs inside the container.
- The final structure of the filesystem looks like this:
```
/dev
/etc
/fingerd
/home
/lib
/proc
/run
/sys
/users.json
```