# {{PROJECT_NAME}} - Monorepo Project Context

## Project Overview

### Mission & Goals

- **Primary Purpose**: [What this monorepo achieves — both backend and mobile]
- **Target Users**: [Who uses this — web users, mobile app users, API consumers]
- **Key Value Propositions**: [Main benefits across platforms]

### Architecture Overview

- **Monorepo Structure**: Backend (Phoenix/Elixir) + Mobile (Flutter/Dart)
- **Backend Architecture**: [e.g., Phoenix LiveView, REST API, GraphQL]
- **Mobile Architecture**: [e.g., Flutter BLoC, Provider, Riverpod]
- **Backend-Mobile Integration**: [How mobile communicates with backend]
- **Data Flow**: [How data moves — mobile to backend and back]
- **Key Integrations**: [External systems, APIs, services]

## Module Directory

### Backend Modules (Phoenix/Elixir)

#### Core Modules

- **Module Name**: [Purpose and responsibilities]
- **Module Name**: [Purpose and responsibilities]

#### Web Modules

- **Module Name**: [Purpose and responsibilities]
- **Module Name**: [Purpose and responsibilities]

#### API Modules

- **Module Name**: [API endpoints exposed to mobile]
- **Module Name**: [WebSocket/Channel handlers for real-time features]

### Mobile Modules (Flutter/Dart)

#### Screens

- **Screen Name**: [UI and functionality]
- **Screen Name**: [UI and functionality]

#### Services

- **Service Name**: [API client, state management]
- **Service Name**: [Business logic services]

#### Models

- **Model Name**: [Data structures in mobile app]
- **Model Name**: [DTOs for API communication]

#### Widgets

- **Widget Name**: [Reusable UI components]
- **Widget Name**: [Custom widgets]

## Tech Stack & Patterns

### Backend Technologies

- **Runtime**: [Check .tool-versions for Elixir/Erlang versions]
- **Framework**: [Phoenix version from mix.exs]
- **Database**: [PostgreSQL, SQLite from mix.exs and config]
- **Testing**: [ExUnit, test factories/fixtures from test/support/]
- **Key Libraries**: [Important dependencies from mix.exs]

### Mobile Technologies

- **Runtime**: [Dart/Flutter versions from pubspec.yaml or .tool-versions]
- **State Management**: [Provider, Riverpod, BLoC]
- **HTTP Client**: [http, dio from pubspec.yaml]
- **Local Storage**: [SharedPreferences, Hive]
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

#### Backend

- **Context Pattern**: [How Phoenix contexts are used]
- **LiveView Patterns**: [Common LiveView impls]
- **Database Patterns**: [Schema and migration conventions]
- **API Patterns**: [How API endpoints are structured]

#### Mobile

- **Navigation**: [Pattern — Navigator 2.0, go_router]
- **State Management**: [How state flows through the app]
- **API Integration**: [How mobile calls backend APIs]
- **Error Handling**: [How errors from API are handled]

## API Contracts & Interfaces

### Backend API Endpoints

- **Endpoint**: [HTTP method, path, purpose]
- **Endpoint**: [Request/response format, auth reqs]

### Mobile API Clients

- **Service Name**: [Which backend endpoints it calls]
- **Service Name**: [Auth handling, error handling]

### WebSocket/Channel Integration

- **Channel Name**: [Real-time features, events]
- **Channel Name**: [Mobile subscription handling]

### Routing Architecture

#### Backend Routes

- **Public Routes**: [Routes accessible without auth]
- **API Routes**: [Routes used by mobile]
- **Protected Routes**: [Routes requiring auth]
- **Pipelines**: [Auth and authorization pipelines]

#### Mobile Navigation

- **Routes**: [App navigation structure]
- **Deep Links**: [Deep linking support]
- **Route Guards**: [Auth/authorization checks]

## Development Guidelines

### Development Rules

- **Centralized Rules**: `@codegen/rules/INDEX.md`
- **Rule Categories**: Phoenix, Flutter, Elixir quality, Dart quality, testing, planning, project structure
- **Backend CI**: [What `make ci` runs in backend/]
- **Mobile CI**: [What `make ci` runs in mobile/]
- **Monorepo CI**: [What `make ci` runs at root]

### Backend Feature Development

- **Context Boundaries**: [How to respect context boundaries]
- **Testing Strategy**: [Fixtures, ExMachina, custom patterns]
- **Database Changes**: [Migration and schema guidelines]
- **API Design**: [How to design endpoints for mobile]

### Mobile Feature Development

- **Screen Development**: [How to create new screens]
- **State Management**: [How to add new state]
- **API Integration**: [How to integrate new backend endpoints]
- **Testing Strategy**: [Widget tests, unit tests, integration tests]

### Integration Points

- **Backend-Mobile Communication**: [How requests/responses work]
- **Authentication**: [How auth tokens managed on both sides]
- **Error Handling**: [How errors propagate backend → mobile]
- **Real-time Updates**: [WebSocket/Channel usage]

### Performance Considerations

#### Backend

- **Database**: [Query optimization patterns]
- **API Response Time**: [Target latency for mobile]
- **Caching**: [Caching strategies]

#### Mobile

- **API Calls**: [Caching, pagination, offline support]
- **UI Performance**: [Widget optimization, lazy loading]
- **Memory Management**: [Image caching, state cleanup]

## Common Pitfalls & Solutions

### Backend

- **Issue**: [Description and solution]
- **Issue**: [Description and solution]

### Mobile

- **Issue**: [Description and solution]
- **Issue**: [Description and solution]

### Integration

- **Issue**: [Common mobile-backend integration problems]
- **Issue**: [API versioning, breaking changes]

### Best Practices

#### Backend

- **Practice**: [Why and how to implement]
- **Practice**: [Why and how to implement]

#### Mobile

- **Practice**: [Why and how to implement]
- **Practice**: [Why and how to implement]

## Deployment Configuration

### Backend Deployment

- **Environment Variables**: [Required env vars]
- **Database Setup**: [Migration strategy]
- **Release Management**: [How releases built and deployed]

### Mobile Deployment

- **Build Configuration**: [Android/iOS build settings]
- **Environment Configuration**: [API URLs for dev/staging/prod]
- **Release Process**: [App store deployment process]
