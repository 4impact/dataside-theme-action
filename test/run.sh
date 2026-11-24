#!/usr/bin/env bash
# Runs publish.sh against the stub theme API in test/stub.py, one case per contract scenario.
# shellcheck disable=SC2329 # the helper functions run through `check` and `trap`.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
SITE=wordpress-test.123456789012.app.dataside.cloud
FAILED=0
STUB_PID=""

cleanup() {
  if [[ -n $STUB_PID ]]; then kill "$STUB_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stub \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# curl reads this file through CURL_HOME and sends every host to the stub.
printf 'connect-to = "::127.0.0.1:%s"\ninsecure\n' "$PORT" >"$WORK/.curlrc"

mkdir -p "$WORK/theme/inc"
printf '/*\nTheme Name: Test\n*/\n' >"$WORK/theme/style.css"
printf '<?php\n' >"$WORK/theme/inc/blocks.php"

# Starts the stub with a scenario, runs publish.sh with the given inputs, and keeps the log in $OUT.
run() {
  local scenario=$1 site=$2 path=$3 code=$4
  shift 4
  if [[ -n $STUB_PID ]]; then kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; fi
  : >"$WORK/requests.log"
  : >"$WORK/output"
  : >"$WORK/summary"
  python3 "$ROOT/test/stub.py" "$PORT" "$WORK/cert.pem" "$WORK/key.pem" "$scenario" "$WORK/requests.log" &
  STUB_PID=$!
  for _ in $(seq 50); do
    curl -sk --connect-to "::127.0.0.1:$PORT" "https://probe/" -o /dev/null && break
    sleep 0.1
  done
  : >"$WORK/requests.log"
  set +e
  OUT=$(cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" CURL_HOME="$WORK" RUNNER_TEMP="$WORK" \
    GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/token?api-version=2.0" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=fake-request-token \
    SITE="$site" THEME_PATH="$path" BIND_CODE="$code" THEME_NAME=acme "$@" "$ROOT/publish.sh" 2>&1)
  CODE=$?
  set -e
}

check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    while IFS= read -r line; do echo "     | $line"; done <<<"$OUT"
    FAILED=1
  fi
}

has() { grep -qF -- "$1" <<<"$OUT"; }
requested() { grep -qF -- "$1" "$WORK/requests.log"; }
no_requests() { [[ ! -s $WORK/requests.log ]]; }
output_is() { grep -qxF -- "$1" "$WORK/output"; }
routes() { jq -r .route "$WORK/requests.log" | paste -sd, -; }
secrets_hidden() {
  ! grep -v '^::add-mask::' <<<"$OUT" | grep -qE 'fake-oidc-token|fake-presigned-signature|X-Amz-Signature'
}

run good "$SITE" theme ""
check "good: succeeds" test "$CODE" = 0
check "good: request order" test "$(routes)" = "POST /publish,PUT upload,POST /commit,GET /result,GET /result"
check "good: upload matches the signed checksum and size" requested '"route": "PUT upload", "ok": true'
check "good: outputs" bash -c "grep -qx 'publish-id=p-1' '$WORK/output' && grep -qx 'status=good' '$WORK/output'"
check "good: step summary names site and publish ID" grep -qF "\`p-1\` to \`$SITE\`" "$WORK/summary"
check "good: log holds no token or pre-signed URL" secrets_hidden
check "good: tokens are masked" has "::add-mask::fake-oidc-token-1"
check "good: commit sends theme" requested '"theme": "acme"'
check "good: success line names the theme" has "as \`acme\`"

run rejected "$SITE" theme ""
check "rejected: fails" test "$CODE" = 1
check "rejected: annotation names file and line" has "::error file=theme/inc/blocks.php,line=42::DataSide rejected theme version p-1: php-lint"
check "rejected: status output" output_is "status=rejected"
check "rejected: message names the theme" has "\`acme\` keeps its newest good theme version, if it has one."

run not-bound "$SITE" theme ""
check "not-bound, no code: fails" test "$CODE" = 1
check "not-bound, no code: requests a binding" test "$(routes)" = "POST /publish,POST /bind"
check "not-bound, no code: binding request body is {}" requested '"route": "POST /bind", "body": {}'
check "not-bound, no code: message" has "Binding requested. DataSide has emailed a code"

run not-bound "$SITE" theme the-code
check "not-bound, with code: says no request matches" has "No binding request matches this code."

run rerun-with-code "$SITE" theme the-code
check "rerun with code: succeeds" test "$CODE" = 0
check "rerun with code: no-pending-binding, then publish" test "$(routes)" = "POST /bind,POST /publish,PUT upload,POST /commit,GET /result,GET /result"
check "rerun with code: bind code is masked" has "::add-mask::the-code"

run bind-with-code "$SITE" theme the-code
check "with code: succeeds" test "$CODE" = 0
check "with code: binds with the code, then publishes" requested '"route": "POST /bind", "body": {"code": "the-code"}, "status": 200'
check "with code: publishes after binding" test "$(routes)" = "POST /bind,POST /publish,PUT upload,POST /commit,GET /result,GET /result"
check "with code: log holds the code only in the mask command" bash -c "! grep -v '^::add-mask::' <<<\"\$1\" | grep -q the-code" _ "$OUT"

run wrong-code "$SITE" theme the-code
check "wrong code: fails with the API message" has "stub refusal wrong-code (wrong-code)"

run trial-in-progress "$SITE" theme ""
check "trial-in-progress: retries, then succeeds" test "$CODE" = 0
check "trial-in-progress: publish sent twice" test "$(routes)" = "POST /publish,POST /publish,PUT upload,POST /commit,GET /result,GET /result"

run publish-5xx "$SITE" theme ""
check "5xx on publish: curl retries, then the action retries token-reused with a new token" test "$(jq -r '"\(.route) \(.status)"' "$WORK/requests.log" | head -n3 | paste -sd, -)" = "POST /publish 500,POST /publish 409,POST /publish 200"
check "5xx on publish: succeeds" test "$CODE" = 0

run s3-refuses "$SITE" theme ""
check "S3 refuses: fails with status and S3 code" has "S3 refused the upload: HTTP 400 BadDigest"

run good "$SITE" theme "" env -u ACTIONS_ID_TOKEN_REQUEST_URL
check "no id-token permission: fails" has "Add \`permissions: id-token: write\` to the job."
check "no id-token permission: sends nothing" no_requests

ln -s style.css "$WORK/theme/link.css"
run good "$SITE" theme ""
check "symbolic link: fails naming it" has "symbolic link, which DataSide refuses: theme/link.css"
check "symbolic link: sends nothing" no_requests
rm "$WORK/theme/link.css"

head -c 52500000 /dev/urandom >"$WORK/theme/big.bin"
run good "$SITE" theme ""
check "over 50 MB: fails" has "over the 50 MB limit"
check "over 50 MB: sends nothing" no_requests
rm "$WORK/theme/big.bin"

run good evil.example.com theme ""
check "site outside app.dataside.cloud: fails" has "must be a DataSide host ending in .app.dataside.cloud"
check "site outside app.dataside.cloud: sends nothing" no_requests
run good "$SITE.evil.example" theme ""
check "site with app.dataside.cloud as a prefix: fails" has "must be a DataSide host"

run good "$SITE" theme "" THEME_NAME=""
check "missing theme: fails" test "$CODE" != 0
check "missing theme: names the input" has "The theme input must be"
check "missing theme: sends nothing" no_requests
run good "$SITE" theme "" THEME_NAME="Bad/Name"
check "bad theme: fails" test "$CODE" != 0
check "bad theme: names the input and value" has "The theme input must be a theme folder name"
check "bad theme: sends nothing" no_requests

run good "$SITE" missing ""
check "path not a directory: fails" has "is not a directory"

exit "$FAILED"
