#!/usr/bin/env bash
# Publishes a built WordPress theme to a DataSide site through the site's theme API.
#
# Inputs arrive as environment variables from action.yml: SITE, THEME_PATH, THEME_NAME and BIND_CODE.
# Never add `set -x` or `curl -v`: both print OIDC tokens and pre-signed URLs to the log.
set -euo pipefail

if [[ -n ${BIND_CODE:-} ]]; then echo "::add-mask::$BIND_CODE"; fi

readonly MAX_SIZE=52428800
readonly POLL_SECONDS=15
readonly WAIT_SECONDS=1200
readonly OUTPUT=${GITHUB_OUTPUT:-/dev/null}
readonly SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
TMP=${RUNNER_TEMP:-$(mktemp -d)}
readonly TMP ARCHIVE=$TMP/theme.tar.gz RESPONSE=$TMP/theme-api-response.json

# Escapes text for a workflow command, so a newline in a server message cannot start another command.
escape() {
  local s=${1//'%'/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}

# Escapes a workflow command property value (file or line).
escape_property() {
  local s
  s=$(escape "$1")
  s=${s//:/%3A}
  printf '%s' "${s//,/%2C}"
}

fail() {
  echo "::error::$(escape "$1")"
  exit 1
}

# Prints the size in MB with one decimal place.
megabytes() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1048576 }'; }

# Sets TOKEN to a new OIDC token for the site and masks it in the log.
oidc_token() {
  TOKEN=$(curl -sS --fail --retry 3 --retry-all-errors \
    -H @<(printf 'Authorization: Bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN") \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$SITE" | jq -r '.value // empty') ||
    fail "Could not get an OIDC token from GitHub."
  [[ -n $TOKEN ]] || fail "GitHub returned no OIDC token."
  echo "::add-mask::$TOKEN"
}

# Sends one theme API request with a new OIDC token.
# Sets STATUS to the HTTP status, and ERROR and MESSAGE from an error body.
api() {
  local method=$1 route=$2 body=${3:-}
  oidc_token
  local args=(-sS --retry 3 --retry-all-errors -o "$RESPONSE" -w '%{http_code}' -X "$method")
  if [[ -n $body ]]; then args+=(-H 'Content-Type: application/json' --data-binary "$body"); fi
  STATUS=$(curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$TOKEN") \
    "https://$SITE/dataside-theme-api$route") || fail "Could not reach the theme API at $SITE."
  ERROR=$(jq -r '.error // empty' "$RESPONSE" 2>/dev/null || true)
  MESSAGE=$(jq -r '.message // empty' "$RESPONSE" 2>/dev/null || true)
}

# Fails with the theme API's message for the last request.
fail_api() {
  fail "The theme API refused ${1}: ${MESSAGE:-HTTP $STATUS} (${ERROR:-no error code})"
}

field() { jq -r "$1 // empty" "$RESPONSE"; }

# 1. Check the job.
[[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] || fail "Add \`permissions: id-token: write\` to the job."
for tool in jq curl tar; do
  command -v "$tool" >/dev/null || fail "This runner has no \`$tool\`. Install it before this step."
done

# 2. Check the inputs.
[[ ${SITE:-} =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*\.app\.dataside\.cloud$ ]] ||
  fail "The site must be a DataSide host ending in .app.dataside.cloud, not '${SITE:-}'."
[[ -d ${THEME_PATH:-} ]] || fail "The path '${THEME_PATH:-}' is not a directory."
[[ -f $THEME_PATH/style.css ]] || fail "The path '$THEME_PATH' has no style.css at its top level."
[[ ${THEME_NAME:-} =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] ||
  fail "The theme input must be a theme folder name: lower-case letters, digits, - and _, starting with a letter or digit, at most 64 characters. Got '${THEME_NAME:-}'."

# 3. Pack the theme.
link=$(find "$THEME_PATH" -type l -print -quit)
[[ -z $link ]] || fail "The theme holds a symbolic link, which DataSide refuses: $link"
tar -czf "$ARCHIVE" -C "$THEME_PATH" .
size=$(wc -c <"$ARCHIVE" | tr -d ' ')
sha256=$( (sha256sum "$ARCHIVE" 2>/dev/null || shasum -a 256 "$ARCHIVE") | cut -d' ' -f1)
((size <= MAX_SIZE)) || fail "The packed theme is $(megabytes "$size"), over the 50 MB limit."
echo "Packed $THEME_PATH: $(megabytes "$size"), SHA-256 $sha256"

# 4. Bind, if a code was given.
if [[ -n ${BIND_CODE:-} ]]; then
  echo "Binding this repository and branch to $SITE"
  api POST /bind "$(jq -n --arg code "$BIND_CODE" '{code: $code}')"
  if [[ $STATUS == 200 ]]; then
    echo "Bound"
  elif [[ $ERROR == no-pending-binding ]]; then
    # A rerun of the binding run: the first run already bound the site, so the publish decides.
    echo "No binding request is pending; checking the existing binding"
  else
    fail_api "the binding code"
  fi
fi

# 5. Publish.
echo "Requesting an upload for $SITE"
deadline=$((SECONDS + WAIT_SECONDS))
while :; do
  api POST /publish "$(jq -n --arg sha256 "$sha256" --argjson size "$size" '{sha256: $sha256, size: $size}')"
  case $ERROR in
    trial-in-progress) echo "Another theme version is on trial; retrying in $POLL_SECONDS seconds" ;;
    # curl resends the same token when it retries a 5xx response, and the theme API may have recorded it already.
    token-reused) echo "The theme API had already seen this token; retrying with a new one in $POLL_SECONDS seconds" ;;
    *) break ;;
  esac
  ((SECONDS < deadline)) || fail "The theme API refused the publish for 20 minutes: ${MESSAGE:-HTTP $STATUS}. Check the site, then run the workflow again."
  sleep "$POLL_SECONDS"
done
if [[ $ERROR == not-bound ]]; then
  [[ -z ${BIND_CODE:-} ]] ||
    fail "No binding request matches this code. Run the workflow by hand without \`bind-code\` to request a new code."
  echo "The site has no binding; requesting a binding code"
  api POST /bind '{}'
  [[ $STATUS == 202 ]] || fail_api "the binding request"
  fail "Binding requested. DataSide has emailed a code to your DataSide account email. Run this workflow again by hand on this branch, with the code as \`bind-code\`."
fi
[[ $STATUS == 200 ]] || fail_api "the publish"
publish_id=$(field .publish_id)
upload_url=$(field .upload_url)
jq -r '.upload_headers // {} | to_entries[] | "\(.key): \(.value)"' "$RESPONSE" >"$TMP/upload-headers"

# 6. Upload. The pre-signed URL carries the authorisation, so the request has no Authorization header.
echo "Uploading $(megabytes "$size")"
upload_status=$(curl -sS --retry 3 --retry-all-errors -o "$RESPONSE" -w '%{http_code}' \
  -T "$ARCHIVE" -H @"$TMP/upload-headers" "$upload_url") || fail "Could not reach S3 to upload the theme."
if [[ $upload_status != 200 ]]; then
  s3_code=$(sed -n 's:.*<Code>\(.*\)</Code>.*:\1:p' "$RESPONSE" | head -n1)
  fail "S3 refused the upload: HTTP $upload_status ${s3_code:-with no error code}"
fi

# 7. Commit.
echo "Committing theme version $publish_id"
api POST /commit "$(jq -n --arg id "$publish_id" --arg sha256 "$sha256" --arg theme "$THEME_NAME" '{publish_id: $id, sha256: $sha256, theme: $theme}')"
[[ $STATUS == 202 ]] || fail_api "the commit"
echo "publish-id=$publish_id" >>"$OUTPUT"

# 8. Wait for the result.
echo "Waiting while $SITE restarts with theme version $publish_id"
deadline=$((SECONDS + WAIT_SECONDS))
while :; do
  api GET "/result?publish_id=$publish_id"
  [[ $STATUS == 200 ]] || fail_api "the result request"
  status=$(field .status)
  case $status in
    good)
      echo "status=good" >>"$OUTPUT"
      echo "Published theme version \`$publish_id\` to \`$SITE\`." >>"$SUMMARY"
      echo "$SITE installed theme version $publish_id as \`$THEME_NAME\`. WordPress serves it while \`$THEME_NAME\` is the active theme."
      exit 0
      ;;
    rejected)
      echo "status=rejected" >>"$OUTPUT"
      reason=$(field .reason)
      file=$(field .file)
      line=$(field .line)
      props=()
      if [[ -n $file ]]; then props+=("file=$(escape_property "$THEME_PATH/$file")"); fi
      if [[ -n $line ]]; then props+=("line=$(escape_property "$line")"); fi
      joined=$(IFS=,; echo "${props[*]}")
      echo "::error${joined:+ $joined}::$(escape "DataSide rejected theme version $publish_id: ${reason:-no reason given}${file:+ in $file}${line:+ line $line}. \`$THEME_NAME\` keeps its newest good theme version, if it has one.")"
      exit 1
      ;;
    pending) ;;
    *) fail "The theme API returned an unknown result '$status'." ;;
  esac
  ((SECONDS < deadline)) || fail "No result after 20 minutes. Check the site, then run the workflow again."
  sleep "$POLL_SECONDS"
done
