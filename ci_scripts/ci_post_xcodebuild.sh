#!/bin/sh
set -e

# Xcode Cloud post-archive script: upload dSYMs and register release with Sentry.
# Only runs on archive actions (skips regular builds / test runs).

if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
  echo "note: skipping Sentry upload (action=$CI_XCODEBUILD_ACTION)"
  exit 0
fi

if [ -z "$SENTRY_AUTH_TOKEN" ]; then
  echo "warning: SENTRY_AUTH_TOKEN not set — dSYMs will NOT be uploaded. Set it as an Xcode Cloud environment secret."
  exit 0
fi

export SENTRY_ORG="psiegel"
export SENTRY_PROJECT="travelmapping"

# Install sentry-cli into a local prefix the script controls (Xcode Cloud bots don't allow sudo).
INSTALL_DIR="$CI_WORKSPACE/.sentry-cli-bin"
mkdir -p "$INSTALL_DIR"
export INSTALL_DIR
curl -sL https://sentry.io/get-cli/ | INSTALL_DIR="$INSTALL_DIR" bash
export PATH="$INSTALL_DIR:$PATH"

echo "sentry-cli version: $(sentry-cli --version)"

# 1. Upload dSYMs from the archive. Non-fatal so release + size analysis still run if
# this step has a transient failure.
DSYM_PATH="$CI_ARCHIVE_PATH/dSYMs"
if [ -d "$DSYM_PATH" ]; then
  echo "Uploading dSYMs from $DSYM_PATH"
  sentry-cli debug-files upload --include-sources "$DSYM_PATH" || echo "warning: dSYM upload failed (not fatal — release + Size Analysis will still run)"
else
  echo "warning: dSYM folder not found at $DSYM_PATH — skipping dSYM upload"
fi

# 2. Create/finalize release and associate commits.
BUNDLE_ID="com.psiegel18.TravelMapping"
RELEASE="${BUNDLE_ID}@${CI_BUNDLE_SHORT_VERSION:-unknown}+${CI_BUILD_NUMBER:-0}"

echo "Registering release $RELEASE"
sentry-cli releases new "$RELEASE"

# Associate commits from the Xcode Cloud checkout. --auto walks the git log from the repo.
if ! sentry-cli releases set-commits "$RELEASE" --auto 2>&1; then
  echo "note: set-commits --auto failed (likely shallow clone). Falling back to current commit only."
  if [ -n "$CI_COMMIT" ]; then
    sentry-cli releases set-commits "$RELEASE" --commit "psiegel18/TravelMapIOS@$CI_COMMIT" || true
  fi
fi

sentry-cli releases finalize "$RELEASE"
echo "Sentry release $RELEASE finalized."

# 3. Size Analysis: upload the xcarchive so Sentry can track app size trends + insights.
if [ -d "$CI_ARCHIVE_PATH" ]; then
  echo "Uploading archive to Sentry for Size Analysis"
  SIZE_ARGS="--build-configuration Release"
  if [ -n "$CI_COMMIT" ]; then
    SIZE_ARGS="$SIZE_ARGS --head-sha $CI_COMMIT"
  fi
  if [ -n "$CI_BRANCH" ]; then
    SIZE_ARGS="$SIZE_ARGS --head-ref $CI_BRANCH"
  fi
  if [ -n "$CI_PULL_REQUEST_NUMBER" ]; then
    SIZE_ARGS="$SIZE_ARGS --pr-number $CI_PULL_REQUEST_NUMBER"
  fi
  if [ -n "$CI_PULL_REQUEST_TARGET_BRANCH" ]; then
    SIZE_ARGS="$SIZE_ARGS --base-ref $CI_PULL_REQUEST_TARGET_BRANCH"
  fi
  SIZE_ARGS="$SIZE_ARGS --head-repo-name psiegel18/TravelMapIOS --vcs-provider github"
  # shellcheck disable=SC2086
  sentry-cli build upload $SIZE_ARGS "$CI_ARCHIVE_PATH" || echo "warning: Size Analysis upload failed (not fatal)"
else
  echo "warning: archive path not found — skipping Size Analysis upload"
fi
