# Development

## Run locally

```sh
make dev
make dev agent=copilot
make dev agent=copilot model=gpt-5.4
```

The Copilot command uses an installed `copilot` executable or falls back to `npx @github/copilot`. Its initial model can be selected with `model=...`; Codex exposes model selection through the active session.

## Tests

```sh
make test
make e2e agent=codex
make e2e agent=copilot
```

Mocked tests use Plenary in a minimal Neovim environment. `PLENARY_DIR` can point to a checkout; otherwise the runner reuses a lazy.nvim installation or downloads a test-only copy into the user cache.

Live E2E requires an authenticated agent and consumes its usage quota. The Codex adjusted-approval test creates temporary files beside the repository to exercise edits outside the agent's workspace.

## Source layout

| Directory | Responsibility |
| --- | --- |
| `lua/omniac/editor/` | Source selections, clipboard images, file paths, and file operations |
| `lua/omniac/prompt/` | Text and attachment prompt construction |
| `lua/omniac/backend/` and `lua/omniac/acp/` | ACP sessions, normalization, and agent updates |
| `lua/omniac/transport/` | Subprocess communication and JSON framing |
| `lua/omniac/ui/` | Chat, input, activity, and rendering |
| `lua/omniac/approval/` | Permissions and adjusted-edit follow-ups |
| `lua/omniac/changes/` | Change tracking and diff review |

Internal planning stays in `docs/FEATURE_TODO.md` and `docs/PROTOCOL_TODO.md`. Record concise user-visible changes in `CHANGELOG.md` under `Unreleased`; assign the release version and date when shipping.
