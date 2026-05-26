# Optimum Context Recipes

Reusable patterns extracted from feature implementations across projects.

## What is a Recipe?

Documented solution to a common dev challenge, reusable across projects. Each recipe:

- Solves a specific, well-defined problem
- General enough to apply beyond a single feature
- Contains impl details and code examples
- Includes trade-offs and pitfalls

## Recipe Categories

- **Data Management**: Sanitization, migration, caching
- **Authentication & Security**: OAuth, JWT, permission systems
- **Performance**: Optimization, query tuning, caching
- **Testing**: Complex scenarios, mock strategies
- **Integration**: Third-party service patterns, API design
- **Error Handling**: Recovery strategies, monitoring
- **UI/UX Patterns**: Complex interactions, state management

## Using Recipes

1. Browse directory for existing patterns
2. Each recipe follows a consistent template
3. Adapt the pattern to your use case
4. Consider documented trade-offs

## Contributing Recipes

Recipes auto-extracted via `ocg update-context <feature>`:

1. Analyzes completed feature impls
2. Identifies reusable patterns
3. Checks for existing similar recipes
4. Creates new recipe files when appropriate

## Recipe Template

- **Problem**: What challenge does this solve?
- **Solution**: High-level approach
- **Implementation**: Step-by-step with code
- **Considerations**: Trade-offs and pitfalls
- **Example Usage**: Real-world application
- **Related Recipes**: Links to similar patterns
