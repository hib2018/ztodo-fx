# fx Adapter Contract

## Boundary

The domain sends a `GenerationRequest`; the adapter returns either a validated Proposal JSON byte slice or a typed
failure. No fx-specific type crosses into `core/` or the persisted state.

## GenerationRequest

```text
issue_key
issue_title
issue_body
workspace_path
exclude_patterns
timeout (default 10 minutes)
max_attempts (default 3 total)
```

## Preconditions

1. `fx` resolves on PATH and reports the required `ask`, `--json`, `--no-save`, stdin, and `permissions --json`
   capabilities.
2. fx authentication is usable without exposing credential content.
3. Effective permissions contain no allow/grant capable of mutation, Terminal execution, external Workspace access,
   or diagnostic upload for this run.
4. The registered Workspace exists and a filtered temporary snapshot was created successfully.

Failure of any precondition prevents model invocation.

## Process invocation

```text
argv: ["fx", "ask", "--json", "--no-save"]
cwd:  <filtered temporary snapshot>
stdin: <generated Proposal prompt UTF-8>
env override: FX_PERMISSION_MODE=ask
stdout limit: 16 MiB
stderr limit: 16 MiB
deadline: 10 minutes by default
TTY: none
```

The adapter passes argv elements directly and never invokes a shell. It preserves the user's authentication-related
environment, overrides only documented run-scoped fx settings, and never prints prompt or response bodies.

## Expected fx envelope

The adapter accepts a single JSON object containing at least:

```json
{
  "output": "accumulated assistant output",
  "final_output": "completed final assistant output",
  "session_id": ""
}
```

Unknown envelope fields are ignored for forward compatibility. `final_output` must be non-empty UTF-8 and contain
only a Proposal JSON object matching `proposal-output.schema.json`. `session_id` is expected to be empty because
`--no-save` is used; a non-empty value is treated as an incompatible contract to avoid hidden persistence.

## Prompt contract

The generated prompt includes:

- trusted Issue identity, title, and body;
- instruction to inspect only the supplied snapshot;
- prohibition on mutation, Terminal, network, external tools, and implementation;
- instruction to return exactly one JSON object and no Markdown fence;
- the Proposal output schema and size limits;
- instruction to cite relevant repository paths in notes without copying secrets or large source blocks.

Issue text is delimited as untrusted data and cannot override the Proposal or permission instructions.

## Retry policy

Retry at most twice after the initial attempt, only for explicitly classified transient provider/network failures.
Use bounded backoff. Do not retry authentication, unsafe permissions, unsupported CLI, timeout, user cancellation,
non-zero tool-permission stop, invalid JSON, invalid Proposal, or output-limit failures.

## Cleanup and persistence

- Remove the temporary snapshot after process termination or cancellation.
- Do not save prompt, `output`, `final_output`, session ID, stderr body, or credentials.
- Persist only the validated Proposal fields and non-sensitive generation metadata.
- If cleanup fails, report the exact private temporary path without deleting outside the owned temporary root.

## Test doubles

Contract tests replace `fx` or inject a ProcessRunner to cover: success, executable missing, auth failure, unsafe rules,
write attempt blocked, Terminal attempt blocked, non-zero exit, signal exit, timeout, cancellation, huge stdout/stderr,
invalid envelope, empty final output, fenced output, invalid Proposal, transient retry, and cleanup failure.

