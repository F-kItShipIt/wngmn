# Terminal demo: the JSON Lines stream, partials building into an endpointed question.
#
# Regenerate from the repository root:
#   vhs docs/tapes/cli.tape
#
# Needs `wngmn` on PATH, the en-US speech model installed, and jq. Replays at --speed 1,
# so the recording runs in the same time the audio does and the latency you see is real.

Output docs/images/cli.gif

Set Shell bash
Set FontSize 18
Set Width 1420
Set Height 640
Set Padding 24
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

# A bare prompt: the point is the output, not whose machine it was recorded on.
Hide
Type "export PS1='$ ' && clear"
Enter
Show

Sleep 800ms
Type "wngmn offline Tests/WngmnAudioTests/Fixtures/two-questions.wav --speed 1 | jq -c ."
Sleep 600ms
Enter

# The clip is 6.7s and plays at 1x, plus model warm-up.
Sleep 14s
