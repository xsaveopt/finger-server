# Finger Server

Finger Server is a small container that answers finger lookups on port 79 for a set of mock users it reads from a JSON file at startup.
The entrypoint turns each entry into an account with a home directory and an optional .plan, then deletes the shells, binaries and package database from the container before starting fingerd, so the daemon ends up running in a filesystem that holds little more than itself and the account files.

## Running it

Images are published to ghcr.io/xsaveopt/finger-server, where releases are tagged latest and by version, and every push to master updates the dev tag.
Mount your users file at /users.json and publish port 79:

```sh
docker run --rm -p 79:79 -v "$PWD/users.json:/users.json:ro" ghcr.io/xsaveopt/finger-server:latest
```

When /users.json is missing or empty the container exits straight away without starting the daemon.
You can also build the image yourself with docker build from the repo root.

## users.json

The file holds a users array of entries, and a bare top-level array of the same entries is accepted too.
The users.json in this repo is a working example.

| Field | Meaning |
| --- | --- |
| `username` | Name that finger looks up, required, made of letters, digits, `_` and `-` and starting with a letter or `_` |
| `gecos` | Full name shown in the lookup |
| `shell` | Shell shown in the lookup, which can be any text |
| `home` | Home directory shown in the lookup |
| `plan` | Text shown as the user's plan, and it can span several lines |

Every entry is checked before any account is created, and a missing username, a value that is not a string or a key outside this table stops the container with an error naming the entry.

Leaving home empty or out gives the user /home/{username}, and the plan is only shown for a home under that path.
Any other value is displayed as written, while the literal value empty hides the home directory from the lookup altogether.

## License

GPL-2.0, see LICENSE.
