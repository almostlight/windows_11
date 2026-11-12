# AGENTS.md

Guidelines for AI coding agents working in this repository. Follow these rules
for all generated or modified code. These guidelines extend the general
AGENTS.md from almostlight/AGENTS with repository-specific rules.

## General Principles

- Write code for readers, not just the compiler. Optimize for clarity first.
- Fail fast and loudly: validate inputs early, surface errors with actionable messages.
- Prefer standard-library and well-established tooling over novel dependencies.
- Never commit secrets, tokens, or machine-specific paths.
- Keep functions short and single-purpose; extract when logic branches on more than two conditions.
- Match the style of nearby code when editing existing files; do not reformat untouched code.

## Repository-Specific Rules

### PowerShell Scripts

- All PowerShell scripts MUST use `[CmdletBinding()]` attribute on functions that accept parameters
- All public functions MUST have comment-based help (SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLE sections)
- Use `Write-Host` for user-facing messages, not for logging
- Use consistent parameter naming: `$Name` for names, `$Path` for paths, `$Url` for URLs
- Avoid global variables; use script-scoped variables (`$Script:VarName`) when necessary
- Always check `$LASTEXITCODE` after external process execution
- Use full cmdlet names (e.g., `Test-Path`, not `tp`)
- Use `$Null` instead of `$null` for consistency with PSScriptAnalyzer

### Logging

- All scripts must implement a logging function (e.g., `Write-SetupLog`, `Write-Log`)
- Log messages must include timestamps and log levels (INFO, WARN, ERROR, SUCCESS, WHATIF)
- Logs should be written to `%USERPROFILE%\scripts\` directory
- Use WhatIf mode consistently to preview changes without execution

### Error Handling

- Use `try/catch/finally` blocks for error handling
- Set `$ErrorActionPreference = 'Stop'` for critical operations
- Always clean up temporary files, even on error
- Provide meaningful error messages that help diagnose issues

### Script Structure

- Scripts should be modular with clear phase separation
- Use functions for reusable logic
- Group related functionality together
- Include a header comment block with SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLE, NOTES

### What If Mode

- All scripts must support `-WhatIf` parameter
- WhatIf mode should show what would happen without making changes
- WhatIf mode should still perform validation and user preference collection
- WhatIf mode should not create log files (or should use a different prefix)

## Commit Messages

- Use imperative mood: "Add feature" not "Added feature"
- Include the script name in the commit message when changing scripts
- Reference related issues or discussions when applicable
- Keep commit messages concise but descriptive
