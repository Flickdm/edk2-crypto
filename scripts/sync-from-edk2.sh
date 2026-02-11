#!/bin/bash
#
# sync-from-edk2.sh
#
# Syncs CryptoPkg from the upstream tianocore/edk2 repository.
# This script extracts CryptoPkg history from edk2 and rebases local commits on top.
#
# Prerequisites:
#   - git-filter-repo: pip install git-filter-repo
#   - Remote 'edk2' pointing to https://github.com/tianocore/edk2.git
#
# Usage:
#   ./scripts/sync-from-edk2.sh [--dry-run]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR=$(mktemp -d)
EDK2_REMOTE="edk2"
EDK2_BRANCH="master"
LOCAL_BRANCH="main"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
fi

cleanup() {
    echo -e "${GREEN}Cleaning up temp directory...${NC}"
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo -e "${GREEN}=== EDK2 CryptoPkg Sync Script ===${NC}"
echo "Repository root: $REPO_ROOT"
echo "Temp directory: $TEMP_DIR"
echo ""

cd "$REPO_ROOT"

# Step 1: Check prerequisites
echo -e "${GREEN}[1/7] Checking prerequisites...${NC}"

if ! command -v git-filter-repo &> /dev/null; then
    echo -e "${RED}Error: git-filter-repo is not installed.${NC}"
    echo "Install with: pip install git-filter-repo"
    exit 1
fi

if ! git remote get-url "$EDK2_REMOTE" &> /dev/null; then
    echo -e "${RED}Error: Remote '$EDK2_REMOTE' not found.${NC}"
    echo "Add with: git remote add edk2 https://github.com/tianocore/edk2.git"
    exit 1
fi

# Step 2: Fetch latest from edk2
echo -e "${GREEN}[2/7] Fetching latest from $EDK2_REMOTE...${NC}"
git fetch "$EDK2_REMOTE"

# Step 3: Find the last synced commit
echo -e "${GREEN}[3/7] Finding sync point...${NC}"

# Get the latest CryptoPkg commit message from our repo (excluding local-only commits)
# We look for commits that match the "CryptoPkg:" pattern from upstream
LAST_LOCAL_CRYPTOPKG_MSG=$(git log --oneline --format="%s" -- CryptoPkg/ | grep -E "^CryptoPkg" | head -1)
echo "Last upstream-style CryptoPkg commit in local: $LAST_LOCAL_CRYPTOPKG_MSG"

# Find the matching commit in edk2
LAST_SYNCED_EDK2_COMMIT=$(git log "$EDK2_REMOTE/$EDK2_BRANCH" --oneline --format="%H %s" -- CryptoPkg/ | grep -F "$LAST_LOCAL_CRYPTOPKG_MSG" | head -1 | cut -d' ' -f1)

if [[ -z "$LAST_SYNCED_EDK2_COMMIT" ]]; then
    echo -e "${YELLOW}Warning: Could not find matching commit in edk2. Will show all recent commits.${NC}"
    LAST_SYNCED_EDK2_COMMIT=$(git log "$EDK2_REMOTE/$EDK2_BRANCH" --oneline -50 -- CryptoPkg/ | tail -1 | cut -d' ' -f1)
fi

echo "Last synced edk2 commit: $LAST_SYNCED_EDK2_COMMIT"

# Step 4: List new commits
echo -e "${GREEN}[4/7] New commits to sync:${NC}"
NEW_COMMITS=$(git log --oneline --reverse "$LAST_SYNCED_EDK2_COMMIT..$EDK2_REMOTE/$EDK2_BRANCH" -- CryptoPkg/)

if [[ -z "$NEW_COMMITS" ]]; then
    echo -e "${GREEN}Already up to date! No new CryptoPkg commits in edk2.${NC}"
    exit 0
fi

echo "$NEW_COMMITS"
COMMIT_COUNT=$(echo "$NEW_COMMITS" | wc -l)
echo ""
echo -e "${YELLOW}Found $COMMIT_COUNT new commit(s) to sync.${NC}"

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}Dry run complete. Run without --dry-run to apply changes.${NC}"
    exit 0
fi

# Step 5: Identify local-only commits to preserve
echo -e "${GREEN}[5/7] Identifying local commits to preserve...${NC}"

# Find commits that are in our repo but not matching any edk2 CryptoPkg commit message
# These are typically local additions like "Add basic build support"
LOCAL_ONLY_COMMITS=()
while IFS= read -r line; do
    COMMIT_HASH=$(echo "$line" | cut -d' ' -f1)
    COMMIT_MSG=$(echo "$line" | cut -d' ' -f2-)
    
    # Check if this commit message exists in edk2's CryptoPkg history
    if ! git log "$EDK2_REMOTE/$EDK2_BRANCH" --oneline --format="%s" -- CryptoPkg/ | grep -qF "$COMMIT_MSG"; then
        LOCAL_ONLY_COMMITS+=("$COMMIT_HASH")
        echo "  Local commit to preserve: $COMMIT_MSG"
    fi
done < <(git log --oneline -20)

echo "Found ${#LOCAL_ONLY_COMMITS[@]} local commit(s) to preserve."

# Step 6: Create filtered edk2 branch
echo -e "${GREEN}[6/7] Creating filtered CryptoPkg branch from edk2...${NC}"

# Clone edk2 to temp directory (shallow for speed, but enough depth for history)
echo "Cloning edk2 to temp directory..."
git clone --single-branch --branch "$EDK2_BRANCH" "$(git remote get-url $EDK2_REMOTE)" "$TEMP_DIR/edk2-filtered"

cd "$TEMP_DIR/edk2-filtered"

# Filter to only CryptoPkg
echo "Filtering to CryptoPkg only..."
git filter-repo --path CryptoPkg/ --force

# Add as remote to our repo and fetch
cd "$REPO_ROOT"
git remote add edk2-filtered "$TEMP_DIR/edk2-filtered" 2>/dev/null || git remote set-url edk2-filtered "$TEMP_DIR/edk2-filtered"
git fetch edk2-filtered

# Step 7: Rebase local commits onto filtered upstream
echo -e "${GREEN}[7/7] Rebasing local commits onto upstream...${NC}"

# Create a backup branch
BACKUP_BRANCH="backup-before-sync-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP_BRANCH"
echo "Created backup branch: $BACKUP_BRANCH"

# Get the filtered upstream branch
FILTERED_BRANCH=$(git branch -r | grep edk2-filtered | head -1 | tr -d ' ')

if [[ ${#LOCAL_ONLY_COMMITS[@]} -gt 0 ]]; then
    # We have local commits to preserve
    # Reset to the filtered upstream, then cherry-pick local commits
    echo "Resetting to filtered upstream..."
    git reset --hard "$FILTERED_BRANCH"
    
    echo "Cherry-picking local commits..."
    for commit in "${LOCAL_ONLY_COMMITS[@]}"; do
        echo "  Cherry-picking $commit..."
        git cherry-pick "$commit" || {
            echo -e "${RED}Conflict during cherry-pick. Please resolve manually.${NC}"
            echo "After resolving, run: git cherry-pick --continue"
            echo "To abort: git reset --hard $BACKUP_BRANCH"
            exit 1
        }
    done
else
    # No local commits, just reset to upstream
    git reset --hard "$FILTERED_BRANCH"
fi

# Cleanup
git remote remove edk2-filtered

echo ""
echo -e "${GREEN}=== Sync Complete ===${NC}"
echo "Backup branch: $BACKUP_BRANCH"
echo ""
echo "To push changes:"
echo "  git push origin $LOCAL_BRANCH --force-with-lease"
echo ""
echo "To undo:"
echo "  git reset --hard $BACKUP_BRANCH"
