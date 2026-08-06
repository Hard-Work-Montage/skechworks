# Moving the UI tests to Burnie

XCUITest drives the real keyboard and the real window server, so a UI run takes
over the screen of whatever machine it runs on. On the Mac you actually draw on
that means every run is either five minutes of hands off, or a handful of
failures that look like bugs and are really you clicking something mid-test. Four
tests failed that way on 2026-08-05, each in about a second.

Burnie is a Mac Mini nobody sits at, with a console session already logged in,
which is the one hard requirement. Everything below is a one-time setup.

## Done already

- [x] Xcode 26.6 copied to `/Applications/Xcode.app` on Burnie — 4 GB, no App
      Store and no Apple ID needed. Burnie runs macOS 26.4.1 and Xcode wants
      26.2, so it's compatible.
- [x] `accomplice` cloned to `~/Development/accomplice` on Burnie.
- [x] `bin/test-remote` written here. It sends the working tree, uncommitted
      changes and all, then runs the suite over there.
- [x] Checked the things that quietly break this: 73 GB free, a real framebuffer,
      sleep already disabled.
- [x] Confirmed the copied binary runs. It currently hangs on `xcodebuild
      -license check`, waiting for an agreement nobody can accept over SSH —
      which is step 1 below, and the reason it has to be step 1. If any xcodebuild
      command appears to hang forever before you've done that, this is why.

## What needs you, at the monitor

Four things, all because Burnie has no passwordless sudo and two of them need a
window to click in.

- [ ] **1. Point the command line tools at Xcode.** Over SSH from anywhere, or in
      Terminal on Burnie itself:
    - [ ] `ssh burnie@100.105.168.11`
    - [ ] `sudo xcode-select -s /Applications/Xcode.app`
    - [ ] `sudo xcodebuild -license accept` — do this before anything else asks
          xcodebuild for anything, or it sits waiting on the licence forever.
    - [ ] `sudo xcodebuild -runFirstLaunch` — installs the bits Xcode downloads
          on first run. Takes a couple of minutes.
    - [ ] Check it took: `xcodebuild -version` should print `Xcode 26.6` instead
          of complaining about the developer directory.

- [ ] **2. Let tests run without an auth prompt.**
    - [ ] `sudo DevToolsSecurity -enable`
    - [ ] This is what stops each run stopping dead on a "Developer Tools Access
          needs to take control" dialog that nobody is there to answer.

- [ ] **3. Stop the screen locking.** It's set to 5 minutes right now, which
      would fail every test after the first five.
    - [ ] System Settings ▸ Lock Screen ▸ "Require password after screen saver
          begins" → Never
    - [ ] Also set "Turn display off when inactive" → Never while you're there.
    - [ ] Leave the session logged in. Locking is what breaks it, not the monitor
          being off — you can turn the monitor back off afterwards.

- [ ] **4. Approve the first run.** This is the one I can't predict.
    - [ ] With the monitor on, run `bin/test-remote` from this Mac.
    - [ ] If macOS asks to let the test runner control your computer, approve it.
          It'll be under Privacy & Security ▸ Accessibility.
    - [ ] If nothing asks, step 2 already handled it and you're done.

- [ ] **5. Optional: passwordless sudo.** Only if you want me to handle root
      things there without pulling you in each time.
    - [ ] `sudo visudo -f /etc/sudoers.d/burnie` and add:
          `burnie ALL=(ALL) NOPASSWD: ALL`
    - [ ] Reasonable for a box you never sit at, and it is still your call.

- [ ] **6. Tell me it's done**, and I'll run the suite there and confirm it comes
      back clean.

## Afterwards

```
bin/test-remote        # everything, UI included, on Burnie
bin/test-remote ""     # skip the UI suite
bin/test               # core + hosted app tests here; these don't steal focus
```

The core suite is 278 tests in half a second and doesn't touch the screen, so it
stays local. Only the UI suite needs to go away.
