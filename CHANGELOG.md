# Changelog

## [1.6.0](https://github.com/feliperun/rec/compare/v1.5.0...v1.6.0) (2026-09-04)


### Features

* color the terminal views with a tty-gated palette ([5e06475](https://github.com/feliperun/rec/commit/5e06475f5b57f93233f27c4c022e28719cb5ade0))
* keep playing after a confirmed cut ([ec2ac2a](https://github.com/feliperun/rec/commit/ec2ac2ab92a20c4c70ad146a4bf408f9d8980dcb))
* redraw the live views as half-block waveforms and play audio in-process ([c4fd03e](https://github.com/feliperun/rec/commit/c4fd03eecc2b0dc7a17e29c138fd11410e679e90))
* redraw the live views as half-block waveforms and play audio in-process ([6e1b8a5](https://github.com/feliperun/rec/commit/6e1b8a5522b3ba7b1e16f2c773cda9187e5a2992))
* region selection, confirmed delete, and a transcript shortcut on play ([57e5588](https://github.com/feliperun/rec/commit/57e55889e329ab189c6e652740cdac7d70c5ef39))


### Bug Fixes

* draw live views on the alternate screen ([ee12cef](https://github.com/feliperun/rec/commit/ee12cef489d2f8a444e5424789e83614a86bb145))
* redraw live views relative to their wrapped rows so resizes don't garble them ([e2c6d51](https://github.com/feliperun/rec/commit/e2c6d51c04b258182340e711dc390ff05378cea6))
* write each live view as one frame per tick with the cursor hidden ([53b43ef](https://github.com/feliperun/rec/commit/53b43ef2828c1a115e6eb087b7b2fd8c8dbd33c9))

## [1.5.0](https://github.com/feliperun/rec/compare/v1.4.0...v1.5.0) (2026-09-02)


### Features

* cut marked intervals in place instead of splitting ([c46178c](https://github.com/feliperun/rec/commit/c46178ced074e912539e267de566d46ac7f989c4))
* live waveform and interactive playback with split ([df51afe](https://github.com/feliperun/rec/commit/df51afe09e12524a44cf0294567ff5c6bb84ff66))


### Bug Fixes

* prevent corrupt partial M4A recordings ([84aefa4](https://github.com/feliperun/rec/commit/84aefa4700be9dedc6cae0b00d77101922681313))

## [1.4.0](https://github.com/feliperun/rec/compare/v1.3.0...v1.4.0) (2026-08-26)


### Features

* Anthropic-compatible LLM providers (deepseek, zai) ([#13](https://github.com/feliperun/rec/issues/13)) ([690b5bf](https://github.com/feliperun/rec/commit/690b5bfd09fbec5cc8fb4ac93319e06aba4c4766))

## [1.3.0](https://github.com/feliperun/rec/compare/v1.2.0...v1.3.0) (2026-08-26)


### Features

* LLM processing pipeline (setup, native refine in transcribe, format) ([7cc825e](https://github.com/feliperun/rec/commit/7cc825e70db763b0eab915da5da014c4b376819c))
* LLM transcript processing (setup, native refine, format) ([8220748](https://github.com/feliperun/rec/commit/82207481347fa223dc8236bcf24a17132aaf9e73))


### Bug Fixes

* resolve numeric selections against newest-first order ([840529a](https://github.com/feliperun/rec/commit/840529af88535243a93f1076f5c9a7294cdf53fa))

## [1.2.0](https://github.com/feliperun/rec/compare/v1.1.3...v1.2.0) (2026-08-26)


### Features

* record natively in M4A/AAC instead of WAV ([017b5ef](https://github.com/feliperun/rec/commit/017b5ef73a3e9ef06ee3cd3ca8f1829e60e788de))
* record natively in M4A/AAC instead of WAV ([0611ebd](https://github.com/feliperun/rec/commit/0611ebde1c5d19a1ffac62e03aa22ad0e74c97d7))

## [1.1.3](https://github.com/feliperun/rec/compare/v1.1.2...v1.1.3) (2026-08-26)


### Bug Fixes

* render transcripts as prose paragraphs per speaker turn ([3a1e11c](https://github.com/feliperun/rec/commit/3a1e11c151b6b469bede0c1e085664d72cbd83fe))
* render transcripts as prose paragraphs per speaker turn ([27f5ff9](https://github.com/feliperun/rec/commit/27f5ff95dd45792a15da18f761bd259ca6320aa3))

## [1.1.2](https://github.com/feliperun/rec/compare/v1.1.1...v1.1.2) (2026-08-26)


### Bug Fixes

* pass curl headers with -H so Deepgram receives authorization ([b079af4](https://github.com/feliperun/rec/commit/b079af43c742d4b25833095e17b1ae736639f6d3))
* pass curl headers with -H so Deepgram receives authorization ([0db98cf](https://github.com/feliperun/rec/commit/0db98cfb4b1ee9cd620eaac7633e165fea6e98af))

## [1.1.1](https://github.com/feliperun/rec/compare/v1.1.0...v1.1.1) (2026-08-26)


### Bug Fixes

* store recordings in home directory ([71ca779](https://github.com/feliperun/rec/commit/71ca77982123918021537c41c29222a7c2684d2a))

## [1.1.0](https://github.com/feliperun/rec/compare/v1.0.1...v1.1.0) (2026-08-26)


### Features

* add rec transcribe with Deepgram and OKF markdown output ([0ebd238](https://github.com/feliperun/rec/commit/0ebd23832ebb255a50b4b3c2371119e0b2a18d60))

## [1.0.1](https://github.com/feliperun/rec/compare/v1.0.0...v1.0.1) (2026-08-22)


### Bug Fixes

* ship arm64-only release builds ([75938b5](https://github.com/feliperun/rec/commit/75938b5926f88eea8d71f892b70e38d91736c143))

## 1.0.0 (2026-08-22)


### Features

* initial release of rec, a terminal audio recorder for macOS ([83998a8](https://github.com/feliperun/rec/commit/83998a8b1c0fe858da5cc6d0aad0e7e5ab995e93))
