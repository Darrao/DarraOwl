# Third-party notices

## Insomnia

Portions of these files are adapted from Insomnia,
https://github.com/krishhgg/Insomnia:

- `mac/Sources/DarraOwlSystem/IOPSPowerSource.swift`: classification of the
  IOKit power source list, `AppleSmartBattery` fallbacks.
- `mac/Sources/DarraOwlCore/PmsetParser.swift`: `pmset` output parsing.
- `mac/Sources/DarraOwlSystem/DisplayPower.swift`: DisplayServices and
  CoreBrightness bridges and their guards.
- `mac/Sources/DarraOwlSystem/CoreAudioControl.swift`: output volume and mute
  by device UID.
- `mac/Sources/DarraOwlSystem/LidObserver.swift`: clamshell notification and
  debounce.
- `mac/Sources/DarraOwlSystem/SysctlProcessControl.swift`: process table reads
  and boot session.
- `mac/Sources/DarraOwlCore/LidCoordinator.swift`: the Docker double probe and
  the open-lid brightness sample (ideas, rewritten).

MIT License

Copyright (c) 2026 Krish Garg

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
