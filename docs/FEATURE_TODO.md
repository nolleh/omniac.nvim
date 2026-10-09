# Feature TODO

This file tracks Omniac-facing product and interaction work that is independent from ACP protocol compatibility.

## Input Experience

- [ ] Add a token usage capsule in the input UI so users can see current budget / consumption at a glance.
- [x] Add a code-block handoff flow from visual mode into `omniac` input so selected code can be forwarded as reference context without manual copy / paste.
- [ ] Let history navigation work with `Ctrl-n` / `Ctrl-p` only, instead of depending on the arrow keys.
- [ ] Add a direct model-selector command / keymap so model selection does not require entering `/model` in chat.

## Session Shortcuts

- [ ] Add a continue-latest-session shortcut that chooses the newest session for the current working directory and uses the agent's advertised load / resume capability.
- [ ] Fall back to the session selector when the latest session cannot be determined safely or cannot be loaded / resumed.

## UX Safety

- [ ] Prevent ambient floating windows opened by normal typing, completion, or file navigation from interrupting the Omniac experience.
- [x] Make `Esc` behavior context-aware so it closes transient UI without accidentally stopping an active chat turn.
- [ ] Audit keymaps and popup handlers that can steal focus while the input is active.

## Prompt Context

- [x] Preserve the source path, line range, filetype, modified state, and captured text when forwarding visual selections.
- [x] Send selected code as ACP embedded context when advertised, with a text fallback for other agents.
- [x] Add the current buffer as a pending prompt reference, linking clean on-disk files and preserving modified buffer contents.
- [ ] Add file-tree integrations that can attach selected paths as prompt references.
- [ ] Define the exact prompt shape for file references and other mixed text-plus-context input.
- [ ] Verify the input pipeline still behaves predictably when the user is already in `omniac://input`.
