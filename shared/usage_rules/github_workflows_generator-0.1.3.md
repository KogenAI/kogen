# github_workflows_generator

GitHub Workflows Generator is an Elixir package that automates GitHub Actions workflow creation. It provides tools to programmatically generate, configure, and manage GitHub workflow files within your project.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:github_workflows_generator, "~> 0.1", only: :dev, runtime: false}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

### Basic Usage

Generate workflows for your project:

```bash
mix github_workflows.generate
```

View available options and parameters:

```bash
mix help github_workflows.generate
```

## Core Concepts

### Mix Task Integration

The package provides a custom Mix task (`github_workflows.generate`) that integrates seamlessly with your Elixir development workflow. This task reads your project configuration and generates appropriate GitHub Actions workflow files.

### Development-Only Dependency

The package is designed as a development-only dependency (`:dev` environment). It doesn't add runtime overhead to your production code—it's purely a build-time tool for generating automation configurations.

### Workflow Automation

The generator automates creation of GitHub Actions workflows, reducing manual YAML configuration and ensuring consistency across your CI/CD pipelines.

## Configuration

### Mix Configuration

Configure the generator in your `mix.exs` file. The package reads your project's `config.exs` and project metadata to determine what workflows to generate.

### Basic Project Setup

Ensure your project has standard Elixir structure:

```
project_root/
├── mix.exs
├── config/
│   └── config.exs
├── lib/
└── .github/
    └── workflows/  (generated here)
```

The generator typically writes workflow files to `.github/workflows/` directory.

## Best Practices

### Integration with Version Control

- Run `mix github_workflows.generate` before committing to ensure workflows are up-to-date
- Include generated workflow files in version control (`.github/workflows/*.yml`)
- Review generated files for accuracy before committing

### Consistency

- Use as a single source of truth for workflow configuration
- Regenerate workflows when project structure changes
- Keep mix.exs configuration synchronized with workflow requirements

### Development Workflow

1. Modify project configuration in `mix.exs` or `config/config.exs`
2. Run `mix github_workflows.generate`
3. Review generated workflow files
4. Commit changes to version control
5. Workflows automatically execute on subsequent pushes to GitHub

### Maintenance

- Regularly check generated workflows for correctness
- Update Mix dependencies to receive workflow generation improvements
- Document any custom workflow modifications separately from generated files
- Use `mix help github_workflows.generate` to discover new options in updates

---

**Version:** 0.1.3
**Source:** [hexdocs.pm/github_workflows_generator](https://hexdocs.pm/github_workflows_generator/)
**Generated:** 2025-10-28
