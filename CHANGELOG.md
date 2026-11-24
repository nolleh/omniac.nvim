# Changelog

## [Unreleased]

## [0.2.0] - 2026-11-24

### Added

- Inline Mermaid diagram rendering through optional Snacks image support and the Mermaid CLI.
- A centered Mermaid diagram viewer with zoom, pan, fit-to-width, and whole-diagram views, opened with `Enter` from a chat diagram.
- Keyboard navigation and scrolling through command, skill, and file suggestions.
- README screenshots showing in-chat Mermaid rendering and the diagram viewer.

### Changed

- Center inline chat diagrams horizontally and preserve a readable scale for tall diagrams, with vertical scrolling and recentering after window resizing.

### Fixed

- Preserve change-review baselines when edit notifications arrive after files have already been saved.
- Prevent advertised agent slash commands from interrupting active ACP turns, while preserving rejected input.
- Preserve suggestion selection and recalled input history during completion and submission.
- Keep input Backspace working when autopairs is installed.
- Include the local `/clear` command in slash-command suggestions.

## [0.1.0] - 2026-11-18

### Added

- Chat with ACP agents inside Neovim, with file, selected-code, and clipboard-image context.
- Review and adjust proposed edits in native diffs, and browse changes by turn or session.
- Follow expandable execution plans and tool output with Bash highlighting and ANSI colors.
- Queue follow-up prompts with attachments or send immediately when the agent supports steering.
- Browse saved sessions and choose the agent's available models and modes.
- Copy chat text and expanded tool output without display padding or inserted line breaks.
- An interactive welcome-card companion, mode and model capsules, and theme-aware window styling.
- A published documentation Wiki, captioned workflow demos, project branding, and an MIT license.
