# Community reply drafts (2026-10-20), not posted

## Igor / Ashray: SystemUI restarts after unlock (ISS-20261020-01)
Thanks, that's a very useful repro (unlock and open QS right away, or screen off then instant fingerprint unlock). Android keeps the crash trace until the next reboot, so no need to catch it live: reproduce it once, then from a PC run
`adb logcat -b crash -d > crash.txt`
and send crash.txt here. If you can, also `adb logcat -b all -d > logcat.txt` right after. Which build are you on (Settings > About) and are you rooted?

## Loic: Chrome freezes then crashes (ISS-20261020-02)
Thanks for the report! Now Playing is a known issue on this build; the fix is ready for the next update. For Chrome, could you open it until it crashes, then from a PC run
`adb logcat -b crash -d > crash.txt`
and send it? Also worth one test: does Chrome still crash with LSPosed modules disabled for Chrome (and Chrome removed from the SuSFS/Zygisk hide list)? That tells us whether it's the ROM or a module.

(FR) Merci ! Now Playing est un problème connu, corrigé dans la prochaine mise à jour. Pour Chrome : ouvre-le jusqu'au crash, puis sur PC `adb logcat -b crash -d > crash.txt` et envoie le fichier. Essaie aussi Chrome sans modules LSPosed pour Chrome, pour voir si c'est la ROM ou un module.
