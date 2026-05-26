# Recipe: Phoenix Docker Build Optimization with GitHub Actions Caching

## Problem

Manual Dockerfiles for Phoenix applications often:

- Use outdated base images that don't match development environments
- Lack proper multi-stage optimization
- Have slow CI/CD build times due to missing cache strategies
- Don't follow Phoenix best practices for releases

This leads to:

- Version mismatches between dev and production
- Unnecessarily large Docker images
- 10-15 minute builds on every CI run
- Manual maintenance of release scripts

## Solution

Use Phoenix's built-in `mix phx.gen.release --docker` generator combined with GitHub Actions Docker Buildx caching to create optimized, maintainable deployments.

**Key Components**:

1. Phoenix-generated multi-stage Dockerfile
2. Release module for production migrations
3. GitHub Actions workflow with Docker Buildx
4. Layer caching strategy (`type=gha,mode=max`)

## Implementation

### Step 1: Generate Phoenix Release Configuration

```bash
# Generate release files
mix phx.gen.release --docker

# Files created:
# - Dockerfile (multi-stage: builder → runtime)
# - .dockerignore
# - lib/your_app/release.ex (migration tasks)
# - rel/overlays/bin/migrate
# - rel/overlays/bin/server
```

### Step 2: Update Dockerfile Base Images

Match your development environment versions from `.tool-versions`:

```dockerfile
# Example: Update to match your versions
ARG ELIXIR_VERSION=1.19.1
ARG OTP_VERSION=28.1.1
ARG DEBIAN_VERSION=bookworm-20241016-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"
```

**Why Debian over Alpine**: Better compatibility, avoids DNS resolution issues and certain build problems (e.g., picosat_elixir).

### Step 3: Configure GitHub Actions Workflow

Create or update `.github/github_workflows.ex` (if using workflow generator):

```elixir
defp deploy_workflow do
  [
    [
      name: "Build & Deploy",
      on: [
        push: [tags: ["v*"]],
        workflow_dispatch: []
      ],
      env: [
        REGISTRY: "ghcr.io",
        IMAGE_NAME: "${{ github.repository }}"
      ],
      jobs: [
        build_and_deploy: build_and_deploy_job()
      ]
    ]
  ]
end

defp build_and_deploy_job do
  [
    name: "Build & Deploy",
    "runs-on": "ubuntu-latest",
    permissions: [
      contents: :read,
      packages: :write
    ],
    steps: [
      checkout_step(),

      # CRITICAL: Set up Buildx for caching
      [
        name: "Set up Docker Buildx",
        uses: "docker/setup-buildx-action@v3"
      ],

      # Container registry login
      [
        name: "Log in to Container Registry",
        uses: "docker/login-action@v3",
        with: [
          registry: "${{ env.REGISTRY }}",
          username: "${{ github.actor }}",
          password: "${{ secrets.GITHUB_TOKEN }}"
        ]
      ],

      # Extract metadata for tags
      [
        id: "meta",
        name: "Extract metadata",
        uses: "docker/metadata-action@v5",
        with: [
          images: "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}",
          tags: ~S"""
          type=ref,event=tag
          type=sha,prefix=sha-
          """
        ]
      ],

      # Build with caching - THE KEY OPTIMIZATION
      [
        name: "Build and push Docker image",
        uses: "docker/build-push-action@v6",
        with: [
          context: ".",
          push: true,
          tags: "${{ steps.meta.outputs.tags }}",
          labels: "${{ steps.meta.outputs.labels }}",
          # Cache configuration
          "cache-from": "type=gha",
          "cache-to": "type=gha,mode=max"
        ]
      ]
    ]
  ]
end
```

Generate workflow file:

```bash
mix github_workflows.generate
```

### Step 4: Verify and Enhance Release Module

Check `lib/your_app/release.ex` and add critical production enhancement:

```elixir
defmodule YourApp.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix installed.
  """
  @app :your_app

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # CRITICAL: Many production databases require SSL
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
```

**Critical production enhancement**:

- `Application.ensure_all_started(:ssl)` in `load_app/0` - Required for production database connections with managed databases (RDS, managed Postgres, etc.)

**Note**: Phoenix's generated code returns a list from the `for` comprehension (e.g., `[{:ok, _, _}]`). This is standard and works correctly with shell scripts. Some projects add an explicit `:ok` return for consistency, but it's not required.

Use in Kubernetes migration job:

```yaml
# k8s/migration-job.yaml
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: your-image:tag
          command: ["./bin/your_app", "eval", "YourApp.Release.migrate()"]
```

## Considerations

### Cache Strategy Trade-offs

**GitHub Actions Cache (`type=gha`)**:

- ✅ Fast read/write (optimized for GHA)
- ✅ Automatic cleanup after 7 days
- ✅ No manual maintenance
- ❌ 10GB limit per repository
- ❌ Only accessible within GitHub Actions

**Registry Cache (`type=registry`)**:

- ✅ No size limit
- ✅ Accessible from anywhere
- ❌ Slower push/pull operations
- ❌ Requires manual cleanup
- ❌ Uses registry storage quota

**Recommendation**: Start with `type=gha`. Switch to registry cache only if you hit the 10GB limit.

### Performance Expectations

**Typical build times with GHA cache**:

- **First build** (no cache): 10-15 minutes
- **Dependency-only changes**: 3-6 minutes (reuse compile cache)
- **Code-only changes**: 2-3 minutes (reuse deps + compile cache)
- **No changes**: 2-5 minutes (cache all layers)

**Improvement**: 50-80% faster builds after first run

### When to Use This Pattern

✅ **Use when**:

- Building Phoenix applications for production
- Using GitHub Actions for CI/CD
- Need reproducible builds matching dev environment
- Want to minimize build times
- Using container registries (GHCR, Docker Hub, etc.)

❌ **Don't use when**:

- Not using GitHub Actions (adapt for other CI systems)
- Building for local development only (use `docker build` directly)
- Need Alpine-based images (requires custom Dockerfile adjustments)

### Common Pitfalls

**Cache not working**:

- **Cause**: Missing `docker/setup-buildx-action@v3` step
- **Fix**: Buildx setup must run BEFORE the build step
- **Debug**: Check build logs for "importing cache manifest from gha" message

**10GB cache limit exceeded**:

- **Symptom**: Cache eviction, inconsistent build times
- **Fix**: Switch to registry cache or cleanup old caches

**Image size too large**:

- **Symptom**: Runtime image > 300MB
- **Fix**: Verify multi-stage build excludes `_build/` and `deps/` from final image

**Version mismatches**:

- **Symptom**: Runtime errors in production
- **Fix**: Update Dockerfile ARG values to match `.tool-versions` exactly

**Migrations fail in production**:

- **Symptom**: Database connection errors during migration
- **Fix**: Ensure `Application.ensure_all_started(:ssl)` is in `load_app/0`
- **Why**: Most production databases (RDS, managed Postgres, etc.) require SSL connections

## Example Usage

### From Spitex Project

**Problem**: Manual Dockerfile used Elixir 1.15-alpine, project needed 1.19.1. No caching, 10+ minute builds every time.

**Solution**: Applied this recipe:

1. Generated Phoenix release config
2. Updated to Elixir 1.19.1 / Erlang 28.1.1 / Debian Bookworm
3. Added GitHub Actions workflow with `type=gha,mode=max` caching
4. Enhanced release module with SSL support
5. Result: Builds dropped to 2-5 minutes after first run

**Files changed**:

- `Dockerfile`: Replaced manual version with generated
- `.github/github_workflows.ex`: Added deploy workflow
- `lib/spitex/release.ex`: Enhanced with SSL support
- `rel/overlays/bin/`: Migration and server scripts

**Verification**:

```bash
# Test Docker build locally
docker build -t app:test .

# Check image size (should be ~150-250MB)
docker images app:test

# Verify release works
docker run --rm app:test version

# Check for cache usage in GitHub Actions logs
# Look for: "importing cache manifest from gha"
```

## Related Recipes

- `elixir-releases-production.md` - General Elixir release patterns
- `kubernetes-deployment-strategies.md` - K8s deployment best practices
- `github-actions-caching.md` - General GHA cache strategies

## References

- [Phoenix Releases Guide](https://hexdocs.pm/phoenix/releases.html)
- [mix phx.gen.release docs](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Release.html)
- [Docker Buildx Cache Backends](https://docs.docker.com/build/cache/backends/)
- [GitHub Actions Cache](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
