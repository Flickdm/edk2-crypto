# Syncing CryptoPkg from EDK2 Upstream

This repository maintains CryptoPkg as a standalone package, extracted from
[tianocore/edk2](https://github.com/tianocore/edk2). This document describes
how to sync with upstream changes.

## Prerequisites

1. **git-filter-repo** - Install with:
   ```bash
   pip install git-filter-repo
   ```

2. **edk2 remote configured**:
   ```bash
   git remote add edk2 https://github.com/tianocore/edk2.git
   ```

## Quick Sync (Automated)

Use the provided sync script:

```bash
# Dry run - see what would be synced
./scripts/sync-from-edk2.sh --dry-run

# Perform the sync
./scripts/sync-from-edk2.sh
```

The script will:
1. Fetch the latest from edk2
2. Identify new CryptoPkg commits
3. Use `git filter-repo` to extract CryptoPkg history
4. Rebase any local-only commits on top
5. Create a backup branch before making changes

After syncing:
```bash
# Review the changes
git log --oneline -20

# Push (force required due to rebase)
git push origin main --force-with-lease
```

## Manual Sync Process

If you prefer to sync manually or need more control:

### Step 1: Check for New Commits

```bash
# Fetch latest
git fetch edk2

# Find your last synced commit (match by commit message)
git log edk2/master --oneline -20 -- CryptoPkg/

# Compare with your history
git log --oneline -20 -- CryptoPkg/
```

### Step 2: Option A - Cherry-pick (For Few Commits)

If only a few commits need syncing:

```bash
# Find the last synced edk2 commit hash
LAST_SYNCED=<hash-of-last-synced-commit>

# List new commits
git log --oneline --reverse $LAST_SYNCED..edk2/master -- CryptoPkg/

# Cherry-pick each (they only touch CryptoPkg so should apply cleanly)
git cherry-pick <commit1> <commit2> ...
```

### Step 2: Option B - Full Re-filter (For Major Sync)

For a complete re-sync or when cherry-picking is complex:

```bash
# Clone edk2 to a temp location
TEMP_DIR=$(mktemp -d)
git clone --single-branch https://github.com/tianocore/edk2.git $TEMP_DIR/edk2

# Filter to CryptoPkg only
cd $TEMP_DIR/edk2
git filter-repo --path CryptoPkg/

# Back in your repo, add as remote and rebase
cd /path/to/edk2-crypto
git remote add edk2-filtered $TEMP_DIR/edk2
git fetch edk2-filtered

# Backup current state
git branch backup-$(date +%Y%m%d)

# Rebase your local commits onto the filtered upstream
git rebase --onto edk2-filtered/master <last-upstream-commit> main

# Cleanup
git remote remove edk2-filtered
rm -rf $TEMP_DIR
```

## Understanding the History

This repo's history structure:

```
[EDK2 CryptoPkg commits] -> [Local-only commits]
        ^                          ^
        |                          |
  Synced from upstream     Your additions
  (matching commit msgs,   (e.g., build support,
   different hashes)        CI configs)
```

Local-only commits are identified by their commit message not matching any
upstream CryptoPkg commit. Examples:
- "Add basic build support"
- CI/workflow additions
- README updates specific to this repo

## Handling Conflicts

If conflicts occur during sync:

1. The script will pause and show the conflicting files
2. Resolve conflicts manually in your editor
3. Stage resolved files: `git add <files>`
4. Continue: `git cherry-pick --continue` or `git rebase --continue`

To abort and restore:
```bash
git reset --hard backup-<timestamp>
```

## Verification

After syncing, verify:

```bash
# Check the new commits are present
git log --oneline -20

# Ensure CryptoPkg builds
# (your build verification steps here)

# Compare file contents with upstream
git diff edk2/master -- CryptoPkg/
```

## Periodic Sync Schedule

Recommend syncing:
- Before any major development work
- After EDK2 stable releases
- Monthly for routine maintenance

## Troubleshooting

**"git-filter-repo is not installed"**
```bash
pip install git-filter-repo
```

**"Remote 'edk2' not found"**
```bash
git remote add edk2 https://github.com/tianocore/edk2.git
```

**"Could not find matching commit"**
The script matches commits by message. If upstream rebased or amended commits,
you may need to manually identify the sync point.

**Large clone taking too long**
Use shallow clone for faster sync:
```bash
git clone --depth=100 --single-branch https://github.com/tianocore/edk2.git
```
