"""desk/bin/lib/settings_env.py — the interim HUMAN_QUEUE_SCHEMA entry in a
profile's settings.json (issue #2183, carry-over).

Used only by desk/bin/cmd/carry-over.sh. Two modes:

  get  SETTINGS              print env.HUMAN_QUEUE_SCHEMA if set (else nothing)
  drop SETTINGS EXPECTED     remove env.HUMAN_QUEUE_SCHEMA when it equals EXPECTED;
                             rewrite the file atomically, keeping its mode and
                             every other key

Exit 0 on success, 4 on a missing or unparseable settings file or a bad mode,
1 when a write fails. Prints one line on stderr for any failure and never
prints a settings value other than the schema name it was asked for.
"""

import json
import os
import sys
import tempfile

ENV_KEY = "HUMAN_QUEUE_SCHEMA"


def fail(code, message):
    sys.stderr.write("human-queue: %s\n" % message)
    sys.exit(code)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        fail(4, "settings file not found: %s" % os.path.basename(path))
    except (OSError, ValueError, RecursionError):
        fail(4, "settings file is unreadable or not JSON: %s" % os.path.basename(path))
    if not isinstance(data, dict):
        fail(4, "settings file is not a JSON object: %s" % os.path.basename(path))
    return data


def get(path):
    env = load(path).get("env")
    if isinstance(env, dict) and isinstance(env.get(ENV_KEY), str):
        sys.stdout.write(env[ENV_KEY] + "\n")
    return 0


def drop(path, expected):
    # Write through a symlink to its target, so the link itself survives.
    path = os.path.realpath(path)
    data = load(path)
    env = data.get("env")
    if not isinstance(env, dict) or env.get(ENV_KEY) != expected:
        return 0
    del env[ENV_KEY]
    folder = os.path.dirname(os.path.abspath(path))
    mode = os.stat(path).st_mode & 0o777
    try:
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except (OSError, UnboundLocalError):
            pass
        fail(1, "could not rewrite the settings file")
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "get":
        return get(argv[2])
    if len(argv) == 4 and argv[1] == "drop":
        return drop(argv[2], argv[3])
    fail(4, "usage: settings_env.py get SETTINGS | drop SETTINGS EXPECTED")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
