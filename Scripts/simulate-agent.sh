#!/bin/zsh
# Pretends to be a coding agent: edits, adds, deletes and occasionally commits
# files in a repo so you can watch Vigil react. Creates a throwaway repo if no
# path is given.
#
# Usage: Scripts/simulate-agent.sh [repo-path] [interval-seconds]
set -euo pipefail

REPO="${1:-}"
INTERVAL="${2:-4}"

if [[ -z "$REPO" ]]; then
  REPO="$(mktemp -d /tmp/vigil-demo.XXXXXX)"
  git -C "$REPO" init -q -b main
  mkdir -p "$REPO/src" "$REPO/tests" "$REPO/.github/workflows"
  cat > "$REPO/src/app.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"


def add(a, b):
    return a + b
PY
  cat > "$REPO/tests/test_app.py" <<'PY'
from src.app import add, greet


def test_add():
    assert add(1, 2) == 3


def test_greet():
    assert greet("x") == "Hello, x!"
PY
  echo "# Demo" > "$REPO/README.md"
  echo "node_modules/" > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=demo -c user.email=demo@example.com commit -q -m "Initial commit"
  git -C "$REPO" checkout -q -b feature/agent-work
  echo "Created demo repo at $REPO (branch feature/agent-work)"
fi

cd "$REPO"
echo "Simulating an agent in $REPO every ${INTERVAL}s. Ctrl-C to stop."
step=0
while true; do
  step=$((step + 1))
  case $((step % 9)) in
    1) printf '\n\ndef multiply(a, b):\n    return a * b\n' >> src/app.py; echo "edit src/app.py" ;;
    2) mkdir -p src/utils; printf 'export const id = (x) => x;\n' > "src/utils/helper_$step.js"; echo "add src/utils/helper_$step.js" ;;
    3) sed -i '' 's/Hello/Howdy/' src/app.py; echo "tweak greeting" ;;
    4) printf 'API_KEY=sk-live-1234567890abcdefghijklmnop\n' > .env; echo "write .env (should be flagged)" ;;
    5) sed -i '' 's/def test_greet/@pytest.mark.skip\ndef test_greet/' tests/test_app.py; echo "skip a test (should be flagged)" ;;
    6) git add -A; git -c user.name=demo -c user.email=demo@example.com commit -q -m "Agent step $step"; echo "commit" ;;
    7) printf 'name: CI\non: push\njobs: {}\n' > .github/workflows/ci.yml; echo "touch CI workflow (should be flagged)" ;;
    8) rm -f "src/utils/helper_$((step - 6)).js" 2>/dev/null || true; echo "delete a helper" ;;
    0) for i in $(seq 1 40); do echo "line $i $RANDOM" >> src/generated.txt; done; echo "append to generated.txt" ;;
  esac
  sleep "$INTERVAL"
done
