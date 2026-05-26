# Recipe: Phoenix/Elixir Repository Hygiene

## Problem

Phoenix/Elixir projects accumulate temporary files, logs, experimental configurations, and sensitive data over time. Without proper organization and .gitignore patterns, repositories become cluttered, insecure, and difficult to navigate.

Common issues:

- NPM cache directories (271MB+) committed to git
- Log files (server.log, debug logs) in repository
- Sensitive files (kubeconfig, credentials) exposed
- Experimental files (Dockerfile.\_, test\_\_.exs) cluttering root
- Backup files (.backup, .bak) using git as version control
- Unclear documentation structure

## Solution

Establish comprehensive .gitignore patterns and repository organization structure from project start. Perform quarterly audits to remove accumulated clutter while archiving (not deleting) important historical files.

## Implementation

### Step 1: Comprehensive .gitignore Patterns

Add these patterns to `.gitignore` for Phoenix/Elixir projects:

```gitignore
# Development logs (Phoenix server, debug logs)
*.log
server.log
server_output.log
logs/
*.log.*
nohup.out
erl_crash.dump

# NPM cache (can be 271MB+)
.npm-cache/
assets/.npm-cache/

# Backup files (git provides version control)
*.backup
*.bak
*~

# Temporary files
*.tmp
*.temp
*.swp
*.swo

# Sensitive files (Kubernetes, credentials)
kubeconfig*.txt
*kubeconfig*
*credentials*
*.env.production
*.pem
*.key

# Experimental files
Dockerfile.*  # Exclude Dockerfile.* but allow main Dockerfile
test_*.exs    # Exclude one-off test scripts (but include test/ directory)
tmp_*.exs
```

### Step 2: Repository Organization Structure

**Documentation Structure:**

```
docs/
├── knowledge/          # Core project knowledge
│   ├── base.md
│   ├── architecture.md
│   ├── patterns.md
│   └── ...
├── iterations/         # Development iterations
│   ├── merged/         # Completed iterations (flat structure)
│   ├── solutions/      # Problem-solving docs (YYYY-MM-DD-title.md)
│   ├── completed/      # Task completion docs
│   └── active-*.md     # Current work
├── archive/            # Historical docs (title-YYYY-MM-DD.md)
├── CURRENT_STATUS.md
├── DEPLOYMENT.md
├── commands.md
└── ui-design-system.md
```

**Script Organization:**

```
priv/repo/
├── seeds.exs
├── promote_admin.exs
├── promote_superuser.exs
└── other_utilities.exs
```

**Root Directory:**

- Keep minimal - only essential files
- No documentation (goes in docs/)
- No scripts (goes in priv/repo/)
- README.md is fine

### Step 3: Quarterly Cleanup Audit

**Audit Checklist:**

1. **Find temporary files:**

```bash
# Log files
find . -name "*.log" ! -path "./deps/*" ! -path "./_build/*" -type f

# Backup files
find . -name "*.backup" -o -name "*.bak" -type f

# Temporary scripts
ls -la test_*.exs tmp_*.exs 2>/dev/null

# Experimental configs
ls -la Dockerfile.* 2>/dev/null
```

2. **Check for sensitive files:**

```bash
# Kubernetes configs
find . -name "*kubeconfig*" -type f

# Environment files
find . -name "*.env.*" -type f

# Credentials
grep -r "password\|secret\|token" --include="*.txt" --include="*.yml" .
```

3. **Check repository size:**

```bash
# NPM cache
du -sh assets/.npm-cache/ 2>/dev/null

# Build artifacts
du -sh _build/ deps/
```

### Step 4: Cleanup Actions

**Archive vs Delete Decision:**

- **Archive** (rename with timestamp): Important historical docs, solution docs
- **Delete**: Log files, backup files, experimental configs, temporary scripts

**Archive Pattern:**

```bash
# Historical documentation
mv guide.md docs/archive/guide-historical-2025-10-31.md

# Solution documentation
mv SOLUTION_FOUND.md docs/iterations/solutions/2025-10-31-problem-description.md
```

**Delete Pattern:**

```bash
# Remove temporary files
rm server.log server_output.log
rm test_*.exs tmp_*.exs
rm Dockerfile.fixed Dockerfile.simple
rm *.backup *.bak

# Remove from git if committed
git rm -r --cached assets/.npm-cache/
```

**Security Pattern (Sensitive Files):**

```bash
# If not pushed yet
git rm --cached kubeconfig.txt
git commit --amend

# If pushed - rotate credentials immediately
# Then remove from history (if absolutely necessary)
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch kubeconfig.txt" \
  --prune-empty --tag-name-filter cat -- --all
```

### Step 5: Verify Cleanup

```bash
# Check .gitignore works
touch test.log server.log
git status | grep -E "test.log|server.log"
# Should not appear as untracked
rm test.log server.log

# Verify project still works
mix compile
mix test

# Verify git status clean
git status
```

## Considerations

**Archive vs Delete Guidelines:**

- Archive if: Historical context valuable, documents problem-solving process, references in other docs
- Delete if: Truly temporary, auto-generated, duplicates git history, logs/caches

**Security First:**

- Sensitive files must be removed immediately
- If pushed to remote, rotate credentials before cleanup
- Use git hooks to prevent future commits of sensitive patterns

**Regular Cadence:**

- Quarterly audits prevent accumulation
- Post-feature cleanup removes experimental files
- Weekly check of git status for unexpected files

**Root Directory Philosophy:**

- Essential files only: README, LICENSE, mix.exs, config files, Dockerfile
- All docs go in docs/, all scripts in priv/repo/
- Clear structure = easier navigation

## Example Usage

**Scenario: Post-feature cleanup after Docker experimentation**

1. Feature created multiple Dockerfile variants during development
2. Final solution merged into main Dockerfile
3. Cleanup process:

```bash
# Verify main Dockerfile is production-ready
cat Dockerfile

# Check what Dockerfile variants exist
ls -la Dockerfile.*

# Verify no references in deployment configs
grep -r "Dockerfile\." k8s/ .github/

# Remove experimental variants
rm Dockerfile.fixed Dockerfile.simple Dockerfile.minimal

# Update .gitignore to prevent future variants
echo "Dockerfile.*" >> .gitignore

# Verify project still builds
docker build -t test:latest .

# Commit cleanup
git add .
git commit -m "chore: remove experimental Dockerfile variants"
```

**Scenario: Discovered npm cache in repository (271MB)**

```bash
# Check current size
du -sh assets/.npm-cache/
# Output: 271M

# Remove from git tracking
git rm -r --cached assets/.npm-cache/

# Update .gitignore
cat >> .gitignore << 'EOF'
# NPM cache
.npm-cache/
assets/.npm-cache/
EOF

# Clean local cache
rm -rf assets/.npm-cache/

# Verify npm still works
cd assets && npm install && cd ..

# Commit cleanup
git add .gitignore
git commit -m "chore: remove npm cache from git tracking"
```

**Scenario: Quarterly audit found sensitive kubeconfig files**

```bash
# Find all kubeconfig files
find . -name "*kubeconfig*" -type f
# Output: ./kubeconfig_clean.txt, ./proper_kubeconfig.txt

# Check if files are tracked
git ls-files | grep kubeconfig

# If tracked and not pushed yet
git rm --cached kubeconfig_clean.txt proper_kubeconfig.txt
git commit --amend -m "chore: remove kubeconfig files (security)"

# If pushed - rotate credentials first!
# Then remove files
git rm kubeconfig_clean.txt proper_kubeconfig.txt

# Update .gitignore
echo "kubeconfig*.txt" >> .gitignore
echo "*kubeconfig*" >> .gitignore

# Verify
git status

# Commit
git commit -m "chore: remove sensitive kubeconfig files"
```

## Related Recipes

- [phoenix-docker-ci-optimization.md](./phoenix-docker-ci-optimization.md) - Docker build optimization patterns
- [phoenix-feature-test-cleanup.md](./phoenix-feature-test-cleanup.md) - Test cleanup patterns

## Success Metrics

- Repository size reduction: 271MB+ from npm cache removal
- Clean `git status`: No unexpected temporary files
- Security: No sensitive files in git history
- Organization: Clear documentation structure, minimal root directory
- Maintainability: Easy to find documentation, scripts in logical locations
