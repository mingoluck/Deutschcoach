# Project Overview

This is a macOS app for practicing spoken German (SwiftUI). The complete design is in `docs/DESIGN.md`. It is the single source of truth; read it before starting any work.

## Communication

- Explain step by step what you are doing and why.
- Do not change decisions already settled in the design document on your own. If a change is needed, explain the reason first and get approval; once approved, update `docs/DESIGN.md` accordingly.

## Technical Conventions

- macOS only, deployment target is the latest macOS. Swift 6 + SwiftUI, using Swift Concurrency (async/await).
- Database: GRDB (Swift Package Manager). All schema changes go through GRDB migrations.
- Speech: `AVSpeechSynthesizer` for reading aloud, `AVAudioEngine` for recording, `SpeechAnalyzer` + `SpeechTranscriber` for recognition. No audio files are stored.
- LLM: call the Claude API via URLSession, using tool calling to force JSON output. When the LLM is unavailable, no practice of any kind is allowed.
- Speech recognition and LLM calls are both abstracted behind protocols, so they are easy to swap and test.
- API keys are stored only in the Keychain, never in code, config files, or git.
- GRDB is currently the only third-party dependency; ask before adding any new dependency.

## Workflow

- Proceed through the milestones in Section 7 of `docs/DESIGN.md` in order, one milestone at a time.
- Before each milestone, present a plan; when it is done, explain how to verify it and make one git commit.
- Whenever building and testing can be done from the command line (`xcodebuild`), run it yourself and fix the errors. For steps that require the Xcode UI (signing, capabilities, first-run permission prompts), tell me exactly how to do them.
