#!/usr/bin/env bash
set -euo pipefail

# Bump the project version (major/minor/patch), commit, tag, and optionally push.
# Usage: ./scripts/bump-version.sh <major|minor|patch> [--push]

BUMP_TYPE="${1:-}"
PUSH="${2:-}"
PROJECT_YML="Clipped/project.yml"

if [[ ! "$BUMP_TYPE" =~ ^(major|minor|patch)$ ]]; then
  echo "Usage: $0 <major|minor|patch> [--push]"
  exit 1
fi

# Get current version from project.yml
CURRENT_VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Error: Could not read MARKETING_VERSION from $PROJECT_YML"
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP_TYPE" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${NEW_VERSION}"

echo "Bumping version: $CURRENT_VERSION -> $NEW_VERSION ($BUMP_TYPE)"

# Update project.yml
sed -i "s/MARKETING_VERSION: \"${CURRENT_VERSION}\"/MARKETING_VERSION: \"${NEW_VERSION}\"/" "$PROJECT_YML"

# Commit and tag
git add "$PROJECT_YML"
git commit -m "Bump version to ${NEW_VERSION}"
git tag -a "$TAG" -m "Release ${TAG}"

echo "Created commit and tag: $TAG"

if [[ "$PUSH" == "--push" ]]; then
  git push origin HEAD
  git push origin "$TAG"
  echo "Pushed commit and tag to origin"
else
  echo "Run 'git push origin HEAD && git push origin $TAG' to trigger the release workflow."
fi
