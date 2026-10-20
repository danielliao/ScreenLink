# Third-party references and notices

ScreenLink has no external Swift package dependencies and does not bundle upstream binaries, icons, translations or device-name databases. It uses frameworks shipped with macOS. The following distinguishes implementation references from distributed dependencies; a public repository being readable does not itself grant reuse rights.

## BLEUnlock — Takeshi Sone

- Project: https://github.com/ts1/BLEUnlock
- Reviewed revision: `2eeb35dcaa4e34ac994380e5dc9c0a692a6f7394`.
- Upstream declares **MIT**, copyright © 2019–2022 Takeshi Sone, in its [README License section](https://github.com/ts1/BLEUnlock#license).
- Reference scope: BLE proximity workflow, system lock-state observation and CoreGraphics Unicode key-event technique, including virtual-key 49 as the Unicode carrier. ScreenLink has its own multi-Mac protocol, policies, UI, event scheduling and tests. It is not a fork or repackaging of BLEUnlock.
- The source review found standard platform API similarities but no vendored BLEUnlock file or substantial verbatim implementation block. Because implementation techniques were consulted, its copyright and full MIT terms are retained below; this notice is not a claim that the ideas are solely original to ScreenLink.
- BLEUnlock's README separately attributes icons under Apache-2.0. ScreenLink does not distribute those icons; its menu uses a system SF Symbol.

### BLEUnlock MIT notice

MIT License

Copyright (c) 2019-2022 Takeshi Sone

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## blueutil — Ivan Kuchin / Frederik Seiffert

- Project: https://github.com/toy/blueutil
- License: [MIT](https://github.com/toy/blueutil/blob/main/LICENSE.txt).
- Used for capability research only. ScreenLink does not bundle or execute blueutil and does not include its Objective-C code or private Bluetooth preferences implementation.

## Apple OpenDirectory

- Reference: [DirectoryService/DirServices.c](https://github.com/apple-oss-distributions/OpenDirectory/blob/main/DirectoryService/DirServices.c).
- Upstream source license: [Apple Public Source License 2.0](https://github.com/apple-oss-distributions/OpenDirectory/blob/main/APPLE_LICENSE).
- Consulted to understand the relationship between directory authentication APIs. No code from that compatibility implementation is distributed here. ScreenLink calls the public OpenDirectory framework shipped with macOS; it does not bundle Apple's open-source implementation.

## Maintenance

These observations reflect the source and reference review for the first public release. Future contributors must re-check the license of any actual code/assets they import and retain its required notices. ScreenLink's MIT license does not relicense third-party material or Apple's SDKs/frameworks.
