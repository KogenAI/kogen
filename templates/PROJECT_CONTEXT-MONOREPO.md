# {{PROJECT_NAME}} - Monorepo Project Context

## Project Overview

### Mission & Goals

- **Primary Purpose**: [What this monorepo project aims to achieve - both backend and mobile]
- **Target Users**: [Who uses this system - web users, mobile app users, API consumers]
- **Key Value Propositions**: [Main benefits delivered across platforms]

### Architecture Overview

- **Monorepo Structure**: Backend (Phoenix/Elixir) + Mobile (Flutter/Dart)
- **Backend Architecture**: [e.g., Phoenix LiveView, REST API, GraphQL, etc.]
- **Mobile Architecture**: [e.g., Flutter BLoC, Provider, Riverpod, etc.]
- **Backend-Mobile Integration**: [How mobile app communicates with backend - REST API, WebSockets, Phoenix Channels]
- **Data Flow**: [How data moves through the system - from mobile to backend and back]
- **Key Integrations**: [External systems, APIs, services]

## Module Directory

### Backend Modules (Phoenix/Elixir)

#### Core Modules

- **Module Name**: [Brief description of purpose and responsibilities]
- **Module Name**: [Brief description of purpose and responsibilities]

#### Web Modules

- **Module Name**: [Brief description of purpose and responsibilities]
- **Module Name**: [Brief description of purpose and responsibilities]

#### API Modules

- **Module Name**: [API endpoints exposed to mobile app]
- **Module Name**: [WebSocket/Channel handlers for real-time features]

### Mobile Modules (Flutter/Dart)

#### Screens

- **Screen Name**: [Brief description of UI and functionality]
- **Screen Name**: [Brief description of UI and functionality]

#### Services

- **Service Name**: [API client, state management, etc.]
- **Service Name**: [Business logic services]

#### Models

- **Model Name**: [Data structures used in mobile app]
- **Model Name**: [DTOs for API communication]

#### Widgets

- **Widget Name**: [Reusable UI components]
- **Widget Name**: [Custom widgets]

## Tech Stack & Patterns

### Backend Technologies

- **Runtime**: [Check .tool-versions for Elixir/Erlang versions]
- **Framework**: [Phoenix version from mix.exs]
- **Database**: [PostgreSQL, SQLite, etc. from mix.exs and config]
- **Testing**: [ExUnit, test factories/fixtures from test/support/]
- **Key Libraries**: [Important dependencies from mix.exs]

### Mobile Technologies

- **Runtime**: [Dart/Flutter versions from pubspec.yaml or .tool-versions]
- **State Management**: [Provider, Riverpod, BLoC, etc.]
- **HTTP Client**: [http, dio, etc. from pubspec.yaml]
- **Local Storage**: [SharedPreferences, Hive, etc.]
- **Testing**: [flutter_test, widget testing, integration testing]
- **Key Packages**: [Important dependencies from pubspec.yaml]

### Backend Coding Conventions

- **File Organization**: [How files are structured in backend/lib/]
- **Naming Patterns**: [Conventions for modules, functions, variables]
- **Code Style**: [Credo, mix format rules]
- **Context Pattern**: [How Phoenix contexts are used]
- **API Design**: [REST conventions, JSON structure]

### Mobile Coding Conventions

- **File Organization**: [How files are structured in mobile/lib/]
- **Naming Patterns**: [Dart naming conventions]
- **Code Style**: [flutter format, analysis_options.yaml rules]
- **State Management Pattern**: [How state is managed across app]
- **Widget Composition**: [How widgets are organized and reused]

### Common Patterns

#### Backend Patterns

- **Context Pattern**: [How Phoenix contexts are used]
- **LiveView Patterns**: [Common LiveView implementations, if any]
- **Database Patterns**: [Schema and migration conventions]
- **API Patterns**: [How API endpoints are structured]

#### Mobile Patterns

- **Navigation**: [Navigation pattern - Navigator 2.0, go_router, etc.]
- **State Management**: [How state flows through the app]
- **API Integration**: [How mobile calls backend APIs]
- **Error Handling**: [How errors from API are handled]

## API Contracts & Interfaces

### Backend API Endpoints

- **Endpoint**: [HTTP method, path, purpose]
- **Endpoint**: [Request/response format, authentication requirements]

### Mobile API Clients

- **Service Name**: [Which backend endpoints it calls]
- **Service Name**: [Authentication handling, error handling]

### WebSocket/Channel Integration (if any)

- **Channel Name**: [Real-time features, events]
- **Channel Name**: [Mobile subscription handling]

### Routing Architecture

#### Backend Routes

- **Public Routes**: [Routes accessible without authentication]
- **API Routes**: [Routes used by mobile app]
- **Protected Routes**: [Routes requiring authentication]
- **Pipelines**: [Authentication and authorization pipelines used]

#### Mobile Navigation

- **Routes**: [App navigation structure]
- **Deep Links**: [Deep linking support, if any]
- **Route Guards**: [Authentication/authorization checks]

## Development Guidelines

### Development Rules

- **Centralized Rules**: This project uses shared development rules via `@codegen/rules/INDEX.md`
- **Rule Categories**: Phoenix, Flutter, Elixir quality, Dart quality, testing, planning, project structure
- **Backend CI**: [What `make ci` runs in backend/]
- **Mobile CI**: [What `make ci` runs in mobile/]
- **Monorepo CI**: [What `make ci` runs at root - both backend and mobile]

### Backend Feature Development

- **Context Boundaries**: [How to respect context boundaries]
- **Testing Strategy**: [Check test/support/ - are fixtures used? ExMachina? Custom patterns?]
- **Database Changes**: [Migration and schema guidelines]
- **API Design**: [How to design endpoints for mobile consumption]

### Mobile Feature Development

- **Screen Development**: [How to create new screens]
- **State Management**: [How to add new state]
- **API Integration**: [How to integrate new backend endpoints]
- **Testing Strategy**: [Widget tests, unit tests, integration tests]

### Integration Points

- **Backend-Mobile Communication**: [How requests/responses work]
- **Authentication**: [How auth tokens are managed on both sides]
- **Error Handling**: [How errors propagate from backend to mobile]
- **Real-time Updates**: [WebSocket/Channel usage, if any]

### Performance Considerations

#### Backend

- **Database**: [Query optimization patterns]
- **API Response Time**: [Target latency for mobile]
- **Caching**: [Caching strategies used]

#### Mobile

- **API Calls**: [Caching, pagination, offline support]
- **UI Performance**: [Widget optimization, lazy loading]
- **Memory Management**: [Image caching, state cleanup]

## Common Pitfalls & Solutions

### Backend Issues

- **Issue**: [Description and solution]
- **Issue**: [Description and solution]

### Mobile Issues

- **Issue**: [Description and solution]
- **Issue**: [Description and solution]

### Integration Issues

- **Issue**: [Common mobile-backend integration problems]
- **Issue**: [API versioning, breaking changes]

### Best Practices

#### Backend

- **Practice**: [Why it's important and how to implement]
- **Practice**: [Why it's important and how to implement]

#### Mobile

- **Practice**: [Why it's important and how to implement]
- **Practice**: [Why it's important and how to implement]

## Deployment Configuration

### Backend Deployment

- **Environment Variables**: [Required env vars for backend]
- **Database Setup**: [Migration strategy]
- **Release Management**: [How releases are built and deployed]

### Mobile Deployment

- **Build Configuration**: [Android/iOS build settings]
- **Environment Configuration**: [API URLs for dev/staging/prod]
- **Release Process**: [App store deployment process]

---

_Last Updated: {{CURRENT_DATE}} - Update this when making significant architectural changes_
