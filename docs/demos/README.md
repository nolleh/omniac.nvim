# README demo videos

All clips use real Neovim UI interactions and live agent execution. Prompts and captions are in English; the videos are silent. Space is the leader key in the isolated recording configuration.

| README section | Video | Length | Keys / workflow | Capture |
| --- | --- | --- | --- | --- |
| Main overview | [Watch](media/main-demo.mp4) | 47.3 s | Selection → request → steer → adjust → apply → review | 42 rows |
| Guide work in progress | [Watch](media/guide-work.mp4) | 14.2 s | Enter · Tab | 64 rows |
| Shape proposed changes | [Watch](media/shape-proposals.mp4) | 15.67 s | Vim editing · Space aa | 64 rows |
| Follow the work | [Watch](media/follow-work.mp4) | 16.3 s | Ctrl-P · Ctrl-T · /changes session | 64 rows |
| Bring your context | [Watch](media/bring-context.mp4) | 12.1 s | Visual selection · Space as · Space ab · Space af | 64 rows |
| Companion | [Watch](media/mascot.mp4) | 8.9 s | Ctrl-K · h / l · j / k | 64 rows |

The main video is the workflow overview. The five feature clips demonstrate one strength at a time and show the relevant default keys in their captions. Feature videos were captured at 168 columns × 64 rows and exported at 1920 × 1440; the overview is 1920 × 1080.

Final MP4 files and their poster images are in [media](media/). README thumbnails link to the corresponding MP4. Raw takes, editing manifests, caption sources, and verification output are retained locally outside the tracked media directory.

The reviewed task summary passes the existing tests and the additional content, order, and unchanged-input checks from `scripts/demo/verify.py`.

## Recording notes

The source projects used for the recorded approval flows live under the Git-ignored `.repro/` directory. The agent's writable workspace remains a separate temporary directory. Files under `/tmp` may be writable by default even outside the agent's working directory; placing both directories there can skip the intended permission diff. Confirm the real permission request before filming an approval feature.

See [main-demo.md](main-demo.md) for the overview shot list and [prepare.py](../../scripts/demo/prepare.py) for preparing a disposable project.
