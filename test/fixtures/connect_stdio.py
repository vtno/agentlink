import json
import subprocess
import sys

with open(sys.argv[1], "wb") as stderr:
    child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
    child.stdin.write(sys.stdin.buffer.readline())
    child.stdin.flush()
    for line in child.stdout:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("id") == 7:
            child.stdin.close()
    sys.exit(child.wait())
