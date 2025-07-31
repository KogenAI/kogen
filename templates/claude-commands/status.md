# /status

Show the current implementation status and progress.

## When to use

Use this command when you want to:

- Get a quick overview of where you are in the implementation
- Check what's been completed and what remains
- Understand the current task and any blockers
- See the todo list status

## How it works

The assistant will:

1. Check the current ./codegen/CONTEXT.md file for implementation stage
2. Review the todo list if one exists
3. Summarize recent progress from the current session
4. Identify the current task and any issues
5. List remaining work items

## Output format

The status report includes:

- **Current Stage**: Which phase/stage of implementation
- **Session Progress**: What's been done in this session
- **Active Task**: What's currently being worked on
- **Blockers**: Any current issues or obstacles
- **Completed**: ✅ List of completed items
- **In Progress**: 🚧 Current work item(s)
- **Remaining**: ⏳ List of pending items
- **Next Steps**: Immediate actions to take

## Example usage

```
/status
```

## Example output

```
## Implementation Status

**Feature**: Authentication System
**Stage**: Phase 2 - Backend Implementation
**Branch**: feature/auth-system

### Current Progress

✅ **Completed:**
- Database schema created
- User model implemented
- Authentication context functions
- Basic tests written

🚧 **In Progress:**
- Implementing OAuth callback handler
- *Blocker*: Need to configure OAuth app credentials

⏳ **Remaining:**
- Frontend login flow
- Session management
- Protected route middleware
- Browser testing
- CI integration

### Session Activity
- Fixed 3 Credo warnings
- Added user registration function
- Started OAuth implementation

### Next Steps
1. Add OAuth credentials to config
2. Complete callback handler
3. Test OAuth flow manually
```
