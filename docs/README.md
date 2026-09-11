# Research notes

Reference material gathered while building this project. Each file records what was
verified, against which source, and — importantly — what could **not** be verified.

These are working notes, not user documentation. The user-facing reference lives in the
[wiki](https://github.com/Pummelchen/MCPSearch/wiki).

| File | Covers |
| --- | --- |
| [provider-api-notes.md](provider-api-notes.md) | Mojeek, Exa and SearXNG API contracts, including the quirks each adapter depends on |
| [openai-mcp-compatibility-report.md](openai-mcp-compatibility-report.md) | OpenAI requirements for an MCP server: the Responses API `mcp` tool, Chat Completions function calling, and the strict-mode schema subset |
| [open-responses-spec-research.md](open-responses-spec-research.md) | The Open Responses specification and what, if anything, it requires of an MCP server |

## How to read them

Every claim is labelled:

- **VERIFIED** — confirmed against official documentation, an official repository, or a
  live endpoint probe.
- **UNVERIFIED** — a community report or inference, with the source quoted.
- **NOT FOUND** — searched for and not located. Recorded so the gap is not mistaken for
  a settled answer.

## Findings that shaped the code

A few of these overturned an assumption that looked obviously true, which is why they
are worth keeping:

| Finding | Where it shows up |
| --- | --- |
| `additionalProperties: false` is **required** by OpenAI strict mode, not risky | Every object in `ToolSchemas` |
| Nullable unions (`["string","null"]`) are the documented way to express an optional field | Optional tool arguments |
| `format: "uri"` is a hard error for OpenAI | Removed from the `web_open` schema |
| `default` is not a supported keyword and is rejected on some deployments | Defaults moved into descriptions |
| Mojeek authenticates by query parameter and returns HTTP 200 for a bad key | `MojeekProvider` |
| Brave reports an invalid token as `422` plus an error code, not `401` | `BraveProvider` |
| Exa answers a *missing* key with `402` and has no score field | `ExaProvider` |
| MCP appears once in the Open Responses specification, as a non-normative example | No server changes were needed for it |

The adapters depend on these details, so the notes are part of the code's rationale
rather than background reading.
