# Voltix 2.5.0 — Android TV & Mobile

Sign-in reliability, catch-up TV accuracy, and playback stability.

## Fixed — sign-in could hang on the Voltix logo

Signing in, whether by pairing code or username and password, could leave the
app on the logo and spinner indefinitely. Nothing failed and no error appeared,
because nothing had actually gone wrong — the app was waiting on a request that
never came back.

Four separate causes, every one of them a network call with no time limit:

- **Cloud settings restore.** For anyone who had signed in before, the app
  restored settings and watch history from cloud storage with no timeout. Those
  calls go to storage directly rather than through the Voltix API, so a slow
  endpoint stalled the app with no trace of it in the server logs. Both are now
  capped at 12 seconds, and sign-in continues without the restore if they run
  long.
- **Streaming server setup.** Adding and authenticating each assigned streaming
  server had no time limits, so one unreachable server held up the whole
  sign-in. Every step is now bounded; a server that cannot be reached is skipped
  and the rest still connect.
- **No backstop on password sign-in.** A 45-second watchdog that forces the app
  onto a screen existed only for pairing-code sign-in. It now covers password
  sign-in too, so the app always reaches a screen.
- **Double sign-in on TV remotes.** A single OK press on a d-pad often registers
  twice, and the "Disconnect & Continue" button acted on both — starting two
  sign-ins at once that fought over the same session. Repeat presses are now
  ignored while a sign-in is running.

## Fixed — SuperSport catch-up showed the wrong times

Catch-up programmes on sport channels were labelled with one programme and
played from another, so a rugby match could appear to start an hour into the
previous one. Every other category was unaffected.

Sport runs short, irregular programmes back to back — the match, the post-match,
the highlights — and the app was picking the first listing within half an hour of
a slot rather than the one that actually covered it. It now matches the closest
programme, prefers one that genuinely overlaps, and takes its start and end times
along with its title, so the tile and the stream agree.

## Fixed — playback stalling on "Loading stream…"

Starting a stream could sit on "Loading stream…" with no error and no way out.
Two waits during player start-up had no time limit; both are now bounded, and a
failure shows a message instead of an endless spinner.

Also corrected a stream-analysis setting that was being given a value roughly
100,000 times too large, which left the player probing far longer than intended
before playback began.

## Improved — catch-up TV

- Catch-up now opens on **DSTV Movies**, followed by **DSTV Sports**, then the
  remaining categories.
- The channel list now matches the web player exactly. The app was working out
  which channels had catch-up on its own and reaching a different answer; both
  now ask the server, so the two agree.
- Programme thumbnails load with far less memory. Artwork was being decoded at
  full source resolution — several megabytes per tile — which on lower-memory TV
  boxes could exhaust memory and close the app when a stream started. Images are
  now decoded at display size, and artwork memory is released before playback
  begins.

---

**Installing:** the Android TV build is for TV boxes and sticks (Chromecast with
Google TV, Xiaomi Mi Box, NVIDIA Shield, Fire TV). The mobile build is for phones
and tablets. Install the one that matches your device.
