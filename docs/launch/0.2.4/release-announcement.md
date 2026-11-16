# Sentwise 0.2.4

A trust-and-distribution release for the Mac app that drafts your post-call follow-up from a transcript, in your voice, with no bot in the meeting. Nothing changes in how you draft.

- **The disk image is signed, not only the app inside it.** The DMG now carries the Genkei Labs Developer ID signature before it is notarized and stapled, and the release pipeline refuses to publish a DMG that Gatekeeper does not accept.
- **macOS 14 stays supported.** The mail library is pinned below the version that requires macOS 15, and a release check guards the pin.
- **Clearer Sign in with Microsoft wording.** The consent screen names what Sentwise asks for, and VoiceOver reads it as one element. Microsoft sign-in stays switched off in this build.
- **Expired sign-in messages read alike** for Google and Microsoft accounts.

Plans: Trial (14 days, no card), Starter $9/month, Pro $19/month, Unlimited $39/month. Requires macOS 14 or later.

Install from https://sentwise.ai/download or `brew install --cask michaeltookes/tap/sentwise`. Existing installs update through the in-app updater (menu bar, Check for Updates…), `brew upgrade --cask sentwise`, or the DMG. Version 0.2.3 is the previous public release.

Full details in [CHANGELOG.md](https://github.com/michaeltookes/sentwise/blob/main/CHANGELOG.md).
