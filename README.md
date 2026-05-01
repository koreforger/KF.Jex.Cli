# KF.Jex.Cli

A command-line interface for executing JEX transformation scripts.

## Overview

This CLI allows you to run JEX scripts directly from the terminal without writing C# code. Perfect for development, testing, and scripting.

## Installation

The CLI is bundled with the VS Code extension. You can also build it standalone:

```powershell
cd KF.Jex.Cli
.\scr\build-rebuild.ps1
```

## Usage

### Basic Execution

```bash
# Run a script with companion input file (script.input.json)
jex script.jex

# Specify input file explicitly
jex script.jex --input data.json

# Write output to file
jex script.jex --output result.json
```

### Input File Convention

By default, the CLI looks for a companion input file:
- Script: `transform.jex`
- Input: `transform.input.json` (auto-discovered)

### Output Formats

```bash
# Compact JSON (default)
jex script.jex --format json

# Pretty-printed JSON
jex script.jex --format pretty

# Detailed output with metadata
jex script.jex --format detailed
```

Detailed output includes:
```json
{
  "success": true,
  "output": { ... },
  "variables": { ... },
  "executionTimeMs": 42,
  "scriptPath": "/path/to/script.jex",
  "inputPath": "/path/to/script.input.json"
}
```

### Watch Mode

Automatically re-run when files change:

```bash
jex script.jex --watch
```

### Metadata

Pass additional metadata to the script:

```bash
jex script.jex --meta config.json
```

Access in script via `$meta`:
```jex
%let env = jp1($meta, "$.environment");
```

## Examples

### Simple Transform

**transform.jex:**
```jex
%let name = jp1($in, "$.user.name");
%set $.greeting = concat("Hello, ", name, "!");
```

**transform.input.json:**
```json
{
  "user": { "name": "Alice" }
}
```

**Run:**
```bash
$ jex transform.jex --format pretty
{
  "greeting": "Hello, Alice!"
}
```

## VS Code Integration

This CLI is used by the VS Code extension's "Run Script" and "Preview" features. The extension invokes it with `--format detailed` to parse results.

## License

MIT License - See [LICENSE.md](LICENSE.md)


