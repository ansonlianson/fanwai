<p align="center">
  <img src=".github/assets/banner.jpg" alt="Fanwai: every song has a story" width="100%">
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/TBykrw6v"><img src="https://img.shields.io/badge/TestFlight-join%20the%20beta-dbcca6?style=flat-square&labelColor=231c14&logo=apple&logoColor=edebe3" alt="TestFlight"></a>
  <img src="https://img.shields.io/badge/iOS-27%2B-dbcca6?style=flat-square&labelColor=231c14&logo=apple&logoColor=edebe3" alt="iOS 27+">
  <img src="https://img.shields.io/badge/Swift-6-dbcca6?style=flat-square&labelColor=231c14&logo=swift&logoColor=edebe3" alt="Swift 6">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.5.39%20%2859%29-dbcca6?style=flat-square&labelColor=231c14" alt="0.5.39 (59)"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-all%20rights%20reserved-8c8578?style=flat-square&labelColor=231c14" alt="license all rights reserved"></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <b>English</b> · <a href="https://fanwai.xyz">Website</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="https://fanwai.xyz/privacy">Privacy</a>
</p>

**番外 (Fanwai)** is an iPhone app. Play a song in Apple Music and it looks up where the song comes from: the original it was adapted from, the film, anime or game it belongs to, its covers and samples, and other songs from the same work. Every story comes with its sources, one tap away.

The app is in Simplified Chinese.

## Install

<a href="https://testflight.apple.com/join/TBykrw6v"><img src="https://img.shields.io/badge/Install%20with%20TestFlight-dbcca6?style=for-the-badge&labelColor=231c14&logo=apple&logoColor=17130e" alt="Install with TestFlight" height="36"></a>

1. Install Apple's [TestFlight](https://apps.apple.com/app/testflight/id899247664) on your iPhone.
2. Open <https://testflight.apple.com/join/TBykrw6v> on the iPhone, tap Accept, then Install.

Requires an iPhone with iOS 27. The public beta currently provides 0.5.38 (58); app source 0.5.39 (59) is in internal testing.

## How it works

Fanwai first asks public databases (Wikidata, MusicBrainz, Wikipedia) and uses the relations they settle. The rest goes to a language model you connect, which searches the web (DeepSeek's search tool, or the web search built into the OpenAI Responses API). Relations and stories the model writes are checked against the pages it cites; anything that does not match is not shown.

There are no accounts, ads or analytics. Your collection and history stay on the phone by default, your model key stays in the phone's keychain, and lookups go straight from the phone to the provider you chose. Lookups made with an invitation code pass through a small relay (`Server/relay`), which records the song and the cost for 90 days. If you choose to submit result feedback, the song, story, related items and limited diagnostics shown at that moment are also sent to the server and kept for 90 days. Feedback does not include your model key, invitation code or complete library. See the [privacy notice](https://fanwai.xyz/privacy) (Chinese).

## Building from source

Requires macOS, Xcode with the iOS 27 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate     # creates Pianwai.xcodeproj
Tools/test.sh         # builds and runs the unit tests on an iPhone simulator
```

The app ships with no model service or key; enter your own in Settings. To run on a device, set your own team and bundle identifier in Xcode. In this public repository, album covers, film posters and photos of people used by the built-in examples are replaced with grey placeholders, and tests that read internal evaluation material or saved copies of articles from other sites are left out.

## Versions

Each public version is a source snapshot prepared for distribution, tagged `v<version>-<build>`. Current app source: 0.5.39 (59), corresponding to the TestFlight build of that number. Server sources reflect the deployed invitation-code management and result-feedback service. See [source notes](SOURCE.md) and the [changelog](CHANGELOG.md).

## Feedback

From 0.5.39, open the Now page’s top-right menu → Feedback → Submit Feedback. The result is captured when you open the form; submitting does not rerun the lookup or use an invitation-code credit. Offline feedback is saved on the phone and retried later. Older builds can use “Send Beta Feedback” in TestFlight. Other ways to reach the author are on [fanwai.xyz](https://fanwai.xyz/support). Report security issues privately under this repository's [Security › Report a vulnerability](https://github.com/ansonlianson/fanwai/security/advisories/new). Issues and pull requests are not accepted here.

## License

The source is published for reading only. **This is not an open-source project**: all rights are reserved, and you may not copy, modify, distribute it or use it to build or publish any app or service without written permission. See [LICENSE](LICENSE).

---

<sub>© 2026 anson · Apple Music, QQ Music, NetEase Cloud Music, DeepSeek and other names and icons belong to their respective owners.</sub>
