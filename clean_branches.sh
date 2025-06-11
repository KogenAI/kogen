#!/bin/bash
set -e

clean_branches() {
    echo "🌿 Removing all orphaned feature branches..."

    ACTIVE_WORKTREES=$(git worktree list --porcelain 2>/dev/null | grep "^branch " | sed 's/^branch refs\/heads\///' | sort | uniq)
    ALL_FEATURE_BRANCHES=$(git for-each-ref --format='%(refname:short)' refs/heads/feature/ 2>/dev/null | sort | uniq)

    if [ -z "$ALL_FEATURE_BRANCHES" ]; then
        echo "   ℹ️  No feature branches found"
        return 0
    fi

    ORPHANED_BRANCHES=""
    for branch in $ALL_FEATURE_BRANCHES; do
        if [ -n "$branch" ] && ! echo "$ACTIVE_WORKTREES" | grep -q "^$branch$"; then
            ORPHANED_BRANCHES="$ORPHANED_BRANCHES$branch "
        fi
    done

    if [ -z "$ORPHANED_BRANCHES" ]; then
        echo "   ℹ️  No orphaned feature branches found"
        return 0
    fi

    echo "   📋 Found orphaned branches to remove:"
    for branch in $ORPHANED_BRANCHES; do
        if [ -n "$branch" ]; then
            echo "      - $branch"
        fi
    done

    echo "   ⚠️  This will permanently delete these branches. Continue? [y/N]"
    read -r confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "   ❌ Operation cancelled"
        return 0
    fi

    for branch in $ORPHANED_BRANCHES; do
        if [ -n "$branch" ]; then
            echo "   🗑️  Deleting branch: $branch"
            git branch -D "$branch" >/dev/null 2>&1 || echo "   ⚠️  Failed to delete branch: $branch"
        fi
    done

    echo "   ✅ Finished removing orphaned branches"
    return 0
}

clean_branches || {
    echo "   ❌ Script encountered an error"
    exit 1
}
