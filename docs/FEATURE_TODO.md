# Feature TODO

This file tracks Omniac-facing product and interaction work that is independent from ACP protocol compatibility.

## Input Experience

- [ ] Add a token usage capsule in the input UI so users can see current budget / consumption at a glance.
- [ ] Add a code-block handoff flow from visual mode into `omniac` input so selected code can be forwarded as reference context without manual copy / paste.
- [ ] Let history navigation work with `Ctrl-n` / `Ctrl-p` only, instead of depending on the arrow keys.

## UX Safety

- [ ] Prevent ambient floating windows opened by normal typing, completion, or file navigation from interrupting the Omniac experience.
- [x] Make `Esc` behavior context-aware so it closes transient UI without accidentally stopping an active chat turn.
- [ ] Audit keymaps and popup handlers that can steal focus while the input is active.

## Prompt Context

- [ ] Preserve enough code-reference metadata when forwarding visual selections so the backend can reconstruct the original source context.
- [ ] Define the exact prompt shape for selected code blocks, file references, and mixed text-plus-code input.
- [ ] Verify the input pipeline still behaves predictably when the user is already in `omniac://input`.
