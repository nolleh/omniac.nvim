# README demo videos

All clips use real Neovim UI interactions and live agent execution. Prompts and captions are in English; the videos are silent. Space is the leader key in the isolated recording configuration.

| README section | Video | Length | Keys / workflow | Capture |
| --- | --- | --- | --- | --- |
| Main overview | [Watch](https://github.com/user-attachments/assets/202ed984-5882-4754-bed7-d551df17e3e0) | 47.3 s | Selection → request → steer → adjust → apply → review | 42 rows |
| Guide work in progress | [Watch](https://github.com/user-attachments/assets/c2cbcb67-4e0a-4b47-b71d-a323031dff9d) | 14.2 s | Enter · Tab | 64 rows |
| Shape proposed changes | [Watch](https://github.com/user-attachments/assets/539a7a13-ffcc-469f-9508-44a2ee49b972) | 15.67 s | Vim editing · Space aa | 64 rows |
| Follow the work | [Watch](https://github.com/user-attachments/assets/0b03a173-727c-4891-849a-b409f606031f) | 16.3 s | Ctrl-P · Ctrl-T · /changes session | 64 rows |
| Bring your context | [Watch](https://github.com/user-attachments/assets/12a8034b-102e-467c-aacb-73f3b8172f02) | 12.1 s | Visual selection · Space as · Space ab · Space af | 64 rows |
| Companion | [Watch](https://github.com/user-attachments/assets/3eda6537-79d1-488f-a9ed-934f5592690c) | 8.9 s | Ctrl-K · h / l · j / k | 64 rows |

The main video is the workflow overview. The five feature clips demonstrate one strength at a time and show the relevant default keys in their captions. Feature videos were captured at 168 columns × 64 rows and exported at 1920 × 1440; the overview is 1920 × 1080.

Videos are hosted as GitHub attachments in [README demo videos](https://github.com/nolleh/omniac.nvim/issues/1). The README embeds the attachment URLs directly, and the Watch links above use those same URLs. Original MP4 files and poster images remain in [media](media/). Raw takes, editing manifests, caption sources, and verification output are retained locally outside the tracked media directory.

The reviewed task summary passes the existing tests and the additional content, order, and unchanged-input checks from `scripts/demo/verify.py`.

## Mermaid screenshots

The README also includes two screenshots of Mermaid rendering and navigation:

| Screenshot | Shows |
| --- | --- |
| [In-chat diagrams](media/mermaid-chat.png) | Rendered diagrams alongside their source in the conversation |
| [Diagram viewer](media/mermaid-viewer.png) | A centered diagram in the floating viewer, with zoom and navigation controls |

## Recording notes

The source projects used for the recorded approval flows live under the Git-ignored `.repro/` directory. The agent's writable workspace remains a separate temporary directory. Files under `/tmp` may be writable by default even outside the agent's working directory; placing both directories there can skip the intended permission diff. Confirm the real permission request before filming an approval feature.

See [main-demo.md](main-demo.md) for the overview shot list and [prepare.py](../../scripts/demo/prepare.py) for preparing a disposable project.
