# CLI Contract

Executable name: `ztodo-fx`

## General rules

- Success is exit code `0`; usage errors are `2`; runtime/integration/storage errors are `1`.
- Human-readable results go to stdout. Diagnostics and actionable errors go to stderr.
- Positions shown to users are one-based. Persistent Task IDs are never reused except after an explicit full clear.
- Destructive commands require an interactive lowercase `y`. Automation may use `--yes`, which is itself an
  explicit confirmation and must appear after the destructive subcommand.
- JSON output is not part of the initial public CLI except where explicitly documented later.

## Diagnostics and setup

```text
ztodo-fx doctor
ztodo-fx help [command]
ztodo-fx version
```

`doctor` reports `gh` presence/authentication, `fx` presence/authentication, required fx capabilities, effective
permission safety, data/config paths, and registered Workspace accessibility without sending model requests.

## Repository and Workspace management

```text
ztodo-fx repo add <owner/name> <absolute-workspace-path>
ztodo-fx repo ls
ztodo-fx repo set-workspace <owner/name> <absolute-workspace-path>
ztodo-fx repo del <owner/name> [--yes]
ztodo-fx repo exclude add <owner/name> <pattern>
ztodo-fx repo exclude ls <owner/name>
ztodo-fx repo exclude del <owner/name> <pattern>
```

- `repo add` validates both values before saving and rejects duplicate Repository or Workspace mappings.
- `repo del` removes active GitHub/Workspace configuration only. Historical IssueSnapshot and Task data remains
  visible as unavailable until explicitly unlinked or deleted.
- Standard exclusions always include VCS-ignored secret conventions and cannot be disabled; custom patterns extend them.

## Issue operations

```text
ztodo-fx issue ls [owner/name]
ztodo-fx issue refresh [owner/name]
ztodo-fx issue show <owner/name#number>
ztodo-fx issue open <owner/name#number>
```

- `ls` uses the latest successful snapshot and marks closed/deleted/unavailable nodes.
- `refresh` obtains Open Issues and refreshes known non-open Issue references without changing Task links.
- `open` delegates browser opening to `gh`; it is not required for Proposal generation.

## Task operations

```text
ztodo-fx task ls [--issue <owner/name#number>]
ztodo-fx task add <title...> [--issue <owner/name#number>] [--parent <task-id>]
ztodo-fx task edit <task-id> <title...>
ztodo-fx task toggle <task-id>
ztodo-fx task move <task-id> <one-based-position>
ztodo-fx task reparent <task-id> (--parent <task-id> | --root) [--issue <owner/name#number>]
ztodo-fx task link <task-id> <owner/name#number>
ztodo-fx task unlink <task-id>
ztodo-fx task del <task-id> (--promote-children | --subtree) [--yes]
ztodo-fx task clear [--yes]
```

- `task ls` always emits a tree. Issue nodes are roots; unlinked Tasks appear below an `Unlinked` root.
- `move` changes order only among current siblings.
- `reparent`, `link`, and `unlink` move the entire subtree and validate cycle/Issue invariants before saving.
- `del` requires exactly one child policy when children exist. `--promote-children` preserves child order at the
  deleted parent's location; `--subtree` lists the full deletion count before confirmation.
- `toggle` never changes descendants.

## Proposal workflow

```text
ztodo-fx proposal generate <owner/name#number>
ztodo-fx proposal show <owner/name#number>
ztodo-fx proposal edit <owner/name#number>
ztodo-fx proposal discard <owner/name#number> [--yes]
ztodo-fx proposal approve <owner/name#number> [--yes]
```

- `generate` requires a registered Workspace, successful `doctor` checks, and explicit invocation. It does not start
  from Issue selection or refresh.
- If the Issue already has a Proposal, replacement requires confirmation before fx is started; cancellation preserves
  the existing draft.
- `edit` provides the established Proposal operations: add, edit, delete, move, reparent, show, quit/save.
- `approve` validates the latest Proposal and State again. Exact-title matches against existing Tasks are displayed.
  A second explicit confirmation is required when any duplicate warning exists.
- Approval appends the Proposal roots after existing Issue-root Tasks, preserves candidate tree order, and removes the
  Proposal in the same Atomic state update.

## Required user-facing error classes

| Class | Required guidance |
|---|---|
| `GitHubCliNotFound` | Install `gh`; link to getting-started |
| `GitHubAuthenticationRequired` | Run `gh auth login` |
| `FxCliNotFound` | Install fx separately; link to getting-started |
| `FxAuthenticationRequired` | Run the applicable `fx login` flow |
| `UnsafeFxPermissions` | Show offending effective allow rules; explain how to revoke them |
| `UnsupportedFxCli` | Show missing capability and detected fx version |
| `WorkspaceUnavailable` | Show registered path and `repo set-workspace` remedy |
| `ProposalGenerationFailed` | Categorize timeout, provider, permission, invalid envelope, invalid Proposal |
| `InvalidState` | Do not overwrite; show state path and backup/recovery guidance |
| `WriteFailed` | Confirm original data was retained and show destination path |

