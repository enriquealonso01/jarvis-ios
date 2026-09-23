# Voice Gateway (live: /opt/voice-gw) — pinned runtime deps that the call path depends on.
# After ANY change here: `systemctl restart jarvis-voice-gateway`, then run
#   scripts/test_callflow.py (repo: jarvis-ios) — must be 11/11 green.
#
# pyrnnoise >=0.4.5  — 0.4.3 calls audiolab Graph(rate=...); audiolab 0.5.2 renamed the kwarg to
#                      sample_rate → RNNoiseFilter.start() crashed the SmallWebRTC input task on
#                      EVERY session (no inbound audio → VAD dead → MediaStreamError → pipeline
#                      cancel). Fixed 2026-09-23; pin enforced.
# audiolab ==0.5.2   — compatible with pyrnnoise 0.4.5's Graph(sample_rate=...).
pyrnnoise>=0.4.5
audiolab==0.5.2
