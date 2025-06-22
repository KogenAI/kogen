# {{PROJECT_NAME}} - Project Context

## Project Overview

### Mission & Goals

- **Primary Purpose**: [What this project aims to achieve]
- **Target Users**: [Who uses this system]
- **Key Value Propositions**: [Main benefits delivered]

### Architecture Overview

- **Architecture Pattern**: [e.g., Phoenix LiveView, MVC, etc.]
- **Data Flow**: [How data moves through the system]
- **Key Integrations**: [External systems, APIs, services]

## Module Directory

### Core Modules

- **Module Name**: [Brief description of purpose and responsibilities]
- **Module Name**: [Brief description of purpose and responsibilities]

### Feature Modules

- **Module Name**: [Brief description of purpose and responsibilities]
- **Module Name**: [Brief description of purpose and responsibilities]

### Infrastructure Modules

- **Module Name**: [Brief description of purpose and responsibilities]
- **Module Name**: [Brief description of purpose and responsibilities]

## Tech Stack & Patterns

### Primary Technologies

- **Backend**: [Check .tool-versions and mix.exs for exact versions]
- **Frontend**: [Check package.json and mix.exs for versions]
- **Database**: [Check mix.exs and config for database details]
- **Testing**: [Check test/support/ structure - fixtures vs factories vs other patterns]

### Coding Conventions

- **File Organization**: [How files are structured]
- **Naming Patterns**: [Conventions for modules, functions, variables]
- **Code Style**: [Formatting and style guidelines]

### Common Patterns

- **Context Pattern**: [How Phoenix contexts are used]
- **LiveView Patterns**: [Common LiveView implementations]
- **Database Patterns**: [Schema and migration conventions]

## API Contracts & Interfaces

### Internal APIs

- **Context APIs**: [Key functions exposed by contexts]
- **LiveView APIs**: [Important LiveView interfaces]
- **Schema APIs**: [Database schema relationships]

### External APIs

- **Third-party Integrations**: [External services and their interfaces]
- **Webhooks**: [Incoming/outgoing webhook patterns]

### Routing Architecture

- **Public Routes**: [Routes accessible without authentication]
- **Authentication Routes**: [Login, registration, password reset flows]
- **Protected Routes**: [Routes requiring authentication, organized by user type]
- **Pipelines**: [Authentication and authorization pipelines used]

## Development Guidelines

### Development Rules

- **Centralized Rules**: This project uses shared development rules via `@codegen/rules/RULES.md`
- **Rule Categories**: Phoenix, Elixir quality, readability, error handling, testing, planning, project structure
- **Setup**: Create symbolic link with `ln -s <rules_dir> codegen/rules` to access all rules

### Feature Development

- **Context Boundaries**: [How to respect context boundaries]
- **Testing Strategy**: [Check test/support/ - are fixtures used? ExMachina? Custom patterns?]
- **Database Changes**: [Migration and schema guidelines]

### Integration Points

- **Authentication**: [How auth is handled]
- **Authorization**: [Permission patterns]
- **Error Handling**: [Error handling conventions]
- **Logging**: [Logging patterns and levels]

### Performance Considerations

- **Database**: [Query optimization patterns]
- **LiveView**: [Performance best practices]
- **Caching**: [Caching strategies used]

## Common Pitfalls & Solutions

### Known Issues

- **Issue**: [Description and solution]
- **Issue**: [Description and solution]

### Best Practices

- **Practice**: [Why it's important and how to implement]
- **Practice**: [Why it's important and how to implement]

---

_Last Updated: {{CURRENT_DATE}} - Update this when making significant architectural changes_
