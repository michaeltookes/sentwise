Audience: everyone with a Sentwise account (trial and paid) who is on 0.2.1 or 0.2.3
From: Sentwise <support@sentwise.ai>
Subject: Sentwise 0.2.4: a signed download, nothing to change
Preheader: macOS 14 stays supported. Update from the menu bar when you are ready.

Hi,

Sentwise 0.2.4 is out. The disk image you download is now signed with the Genkei Labs Developer ID before it is notarized, and our release process refuses to publish a download that Gatekeeper does not accept. Earlier downloads opened fine because they were notarized, but the container itself carried no signature.

What else changed:

1. macOS 14 stays supported. A release check now guards the mail library version that would otherwise raise the minimum.
2. The Sign in with Microsoft screen names exactly what Sentwise asks for, and VoiceOver reads it as one element. Sign in with Microsoft is still switched off.
3. The "your sign-in expired" message reads the same for Google and Microsoft accounts.

If you are coming from 0.2.1, 0.2.3 also made follow-up drafts greet the right person and assign action items to the right owners, and fixed Settings in the app menu.

What you need to do: nothing. Sentwise updates itself through the built-in updater, or you can choose Check for Updates… in the menu bar. You can also download the DMG from https://sentwise.ai/download or run `brew upgrade --cask sentwise`. Your plan, mailboxes and voice profile are unchanged.

If anything looks wrong, use Report a Problem in the menu bar or reply to this email.

Sentwise
https://sentwise.ai · Full changelog: https://github.com/michaeltookes/sentwise/blob/main/CHANGELOG.md

You are receiving this because you have a Sentwise account. [unsubscribe link from the sending tool]
