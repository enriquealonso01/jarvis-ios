#!/usr/bin/env python3
"""One Pipecat pipeline per live voice surface (browser WebRTC or Discord).

Pipeline (v2, 2026-09-16):

  transport.in → Whisper STT → user aggregator (Silero VAD + smart-turn v3
  semantic end-of-turn) → streaming LLM with tools (brain.py) → ElevenLabs
  Flash (websocket, sentence-chunked) → transport.out → assistant aggregator

Pipecat owns barge-in (allow_interruptions), turn-taking, sentence chunking,
the function-call loop and context. This file only wires it up, relays a live
transcript + state to the page over the WebRTC data channel, measures latency,
and records each exchange back into the Control Center's voice threads so the
rest of JARVIS remembers the call.
"""
from __future__ import annotations

import asyncio
import json as _json
import os
from datetime import datetime, timezone
import time
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Optional

from loguru import logger

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import (
    AudioRawFrame,
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    FunctionCallInProgressFrame,
    FunctionCallResultFrame,
    InterimTranscriptionFrame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMMessagesAppendFrame,
    LLMTextFrame,
    OutputTransportMessageUrgentFrame,
    TranscriptionFrame,
    TTSSpeakFrame,
    TTSTextFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.observers.base_observer import BaseObserver, FramePushed
from pipecat.observers.user_bot_latency_observer import UserBotLatencyObserver
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.turns.user_turn_strategies import ExternalUserTurnStrategies
from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
from pipecat.services.whisper.stt import Model as WhisperModel
from pipecat.services.whisper.stt import WhisperSTTService
from pipecat.transcriptions.language import Language
from pipecat.transports.base_transport import TransportParams
from pipecat.audio.filters.rnnoise_filter import RNNoiseFilter
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport

import brain as brain_mod

log = logger

ELEVEN_MODEL = os.environ.get("VOICE_TTS_MODEL", "eleven_flash_v2_5")
VOICE_ID = os.environ.get("VOICE_TTS_VOICE_ID", "3xOZA9B4KTVQOOZaSbXn")   # the cloned JARVIS voice
WHISPER_MODEL = os.environ.get("VOICE_STT_MODEL", "base")
GREETING = os.environ.get("VOICE_GREETING", "Ready, sir.")


def greeting() -> str:
    return brain_mod.cfg("VOICE_GREETING", GREETING)
VAD_STOP_SECS = float(os.environ.get("VOICE_VAD_STOP_SECS", "0.2"))

# ---- wiring injected by gateway.py -------------------------------------------
dashboard: Optional[brain_mod.Dashboard] = None
record_turn: Optional[Callable[..., None]] = None


def setup(dash: brain_mod.Dashboard, record_turn_fn: Callable[..., None]) -> None:
    global dashboard, record_turn
    dashboard = dash
    record_turn = record_turn_fn


def get_stt() -> WhisperSTTService:
    """A NEW service per session: a Pipecat processor belongs to one pipeline
    (sharing one left dangling segment tasks). The model files are cached on
    disk, so construction is ~1 s for `base`; gateway.py warms that cache."""
    name = brain_mod.cfg("VOICE_STT_MODEL", WHISPER_MODEL)
    try:
        model = WhisperModel(name)
    except ValueError:
        model = name
    return WhisperSTTService(model=model, device="cpu", compute_type="int8",
                             no_speech_prob=0.6, language=Language.EN)


def get_tts() -> ElevenLabsTTSService:
    # voice_settings pinned: the voice's saved stability (0.5) is the most
    # expressive range and measurably drifts across a long session ("sounds
    # like a different person"). 0.75 keeps one identity (voice-fix 2026-09-11).
    return ElevenLabsTTSService(
        api_key=os.environ.get("ELEVENLABS_API_KEY", ""),
        voice_id=brain_mod.cfg("VOICE_TTS_VOICE_ID", VOICE_ID),
        model=brain_mod.cfg("VOICE_TTS_MODEL", ELEVEN_MODEL),
        sample_rate=24000,
        params=ElevenLabsTTSService.InputParams(
            stability=0.75, similarity_boost=0.75, style=0.0,
            use_speaker_boost=True, speed=1.0, auto_mode=True),
    )


# ----------------------------------------------------------- UI relay -------
def _turn_ts() -> float:
    """Wall-clock stamp for a transcript turn (epoch seconds)."""
    return round(time.time(), 3)


def _turn_iso(ts: float) -> str:
    """UTC ISO-8601 for a transcript turn. The gateway always emits UTC
    (suffix Z); rendering in the phone's local timezone is the client's job."""
    return (datetime.fromtimestamp(ts, tz=timezone.utc)
            .isoformat(timespec="milliseconds").replace("+00:00", "Z"))


class AudioCounterObserver(BaseObserver):
    """Counts raw audio frames per direction (2026-09-30 round 2, bug B):
    gateway-side proof of what actually flowed. in=N proves the phone's MIC
    reached us; out=M proves we SENT bot audio. If M>0 and Enrique still
    heard nothing, the fault is device-side playout (CallKit answer path).
    Gateway turn-latency alone is NOT proof of audible audio."""

    def __init__(self, session: "VoiceSession"):
        super().__init__()
        self._s = session

    async def on_push_frame(self, data: FramePushed):
        f = data.frame
        if not isinstance(f, AudioRawFrame):
            return
        # UPSTREAM = device → gateway (mic), DOWNSTREAM = gateway → device.
        if data.direction is not None and getattr(data.direction, "name", "") == "UPSTREAM":
            self._s.count_audio_in(f)
        else:
            self._s.count_audio_out(f)


class UIObserver(BaseObserver):
    """Watches frames go by and mirrors transcript + state to the client over
    the data channel, and records each finished exchange to the dashboard."""

    def __init__(self, session: "VoiceSession"):
        super().__init__()
        self._s = session
        self._seen: set = set()
        self._assistant_buf: List[str] = []
        self._pending_user: str = ""
        self._last_user: str = ""
        self._last_flushed: str = ""
        self._silent_until: float = 0.0   # set by stay_silent; see below

    async def on_push_frame(self, data: FramePushed):
        f = data.frame
        fid = getattr(f, "id", None)
        key = (type(f).__name__, fid)
        if key in self._seen:
            return
        self._seen.add(key)
        if len(self._seen) > 4000:
            self._seen = set(list(self._seen)[-1000:])
        s = self._s
        if isinstance(f, InterimTranscriptionFrame):
            await s.ui({"type": "interim", "text": f.text})
        elif isinstance(f, TranscriptionFrame):
            text = (f.text or "").strip()
            if text:
                self._pending_user = (self._pending_user + " " + text).strip()
                self._last_user = self._pending_user
                await s.ui({"type": "transcript", "role": "user", "text": text,
                            **s.turn_ts_fields()})
        elif isinstance(f, UserStartedSpeakingFrame):
            await s.ui({"type": "state", "state": "listening"})
        elif isinstance(f, UserStoppedSpeakingFrame):
            s.mark_user_stopped()
            await s.ui({"type": "state", "state": "thinking"})
        elif isinstance(f, LLMFullResponseStartFrame):
            self._assistant_buf = []
        elif isinstance(f, TTSTextFrame):
            # The realtime service emits BOTH LLMTextFrame and TTSTextFrame for
            # its spoken transcript; counting only TTSTextFrame avoids doubling.
            if time.time() < self._silent_until:
                return          # he asked for silence: nothing reaches the page
            if f.text:
                self._assistant_buf.append(f.text)
                await s.ui({"type": "partial", "role": "assistant", "text": f.text})
        elif isinstance(f, BotStartedSpeakingFrame):
            await self._note_turn_latency()
            await s.ui({"type": "state", "state": "speaking"})
        elif isinstance(f, BotStoppedSpeakingFrame):
            await self._flush_assistant()
            await s.ui({"type": "state", "state": "idle"})
        elif isinstance(f, LLMFullResponseEndFrame):
            await self._flush_assistant()
        elif isinstance(f, FunctionCallInProgressFrame):
            # "Be quiet" has to silence the page too: OpenAI's post-tool response
            # can leak a word before brain._cancel_followup kills it, and a leaked
            # "Goodbye," in the transcript is as wrong as a spoken one.
            if f.function_name == "stay_silent":
                self._silent_until = time.time() + 2.5
                self._assistant_buf = []
                s._user_stopped_at = None   # no answer is coming; do not time it
            await s.ui({"type": "tool", "name": f.function_name, "status": "start"})
        elif isinstance(f, FunctionCallResultFrame):
            # Async tools (ask_jarvis) stream intermediate updates with
            # is_final=False; only the final result ends the "working" state.
            props = getattr(f, "properties", None)
            final = getattr(props, "is_final", True) if props is not None else True
            await s.ui({"type": "tool", "name": f.function_name,
                        "status": "done" if final else "update"})

    async def _note_turn_latency(self) -> None:
        """His turn ended -> the bot started speaking. Pipecat's own latency
        observer does not fire on the realtime brain, so this is the only place
        the number exists. Recorded to metrics.db and shown on the orb, exactly
        like the cascade path does it."""
        s = self._s
        started = getattr(s, "_user_stopped_at", None)
        if not started:
            return
        s._user_stopped_at = None
        ms = (time.time() - started) * 1000.0
        # 10 s, not 30: a mark left over from a turn that was never answered (he
        # said "stop", or the reply arrived as an async ask_jarvis relay minutes
        # later) would otherwise be recorded as a huge latency and poison the very
        # numbers this exists to produce. One real 17.7 s reading did exactly that.
        if ms <= 0 or ms > 10000:
            return
        try:
            s._lat.append(ms)
            s.metrics["turns"] = len(s._lat)
            s.metrics["last_latency_ms"] = round(ms)
            s.metrics["avg_latency_ms"] = round(sum(s._lat) / len(s._lat))
            await s.ui({"type": "metrics", "latency_ms": round(ms),
                        "avg_ms": s.metrics["avg_latency_ms"], "turn": len(s._lat)})
            if record_turn:
                record_turn(s.surface, total_ms=ms, ok=1,
                            note=f"observer:{s.brain_label}")
            log.info("turn latency {:.0f} ms (turn {}) {}", ms, len(s._lat), s.thread_id)
        except Exception as exc:  # noqa: BLE001 - metrics must never break a call
            log.debug("latency note failed: {}", exc)

    async def _flush_assistant(self):
        if time.time() < self._silent_until:
            self._assistant_buf = []
            return
        if not self._assistant_buf:
            return
        text = " ".join(t.strip() for t in self._assistant_buf if t.strip())
        self._assistant_buf = []
        if not text:
            return
        try:
            text = brain_mod.speakable(text)
        except Exception:  # noqa: BLE001 - display-only, never break a call
            pass
        # An interrupted response re-emits its tail after the flush; drop
        # near-duplicates of what was just shown.
        import re as _re
        w_new = set(_re.findall(r"[a-z0-9']+", text.lower()))
        w_old = set(_re.findall(r"[a-z0-9']+", self._last_flushed.lower()))
        if w_new and w_old and len(w_new & w_old) / len(w_new) >= 0.5:
            return
        # Echoed tail: flush ending in a long verbatim run of the previous
        # flush's ending (partial interrupt re-emit slips under the ratio).
        t_old = [w for w in _re.findall(r"[a-z0-9']+", self._last_flushed.lower()) if w]
        t_new = [w for w in _re.findall(r"[a-z0-9']+", text.lower()) if w]
        for k in (12, 8, 6, 4):
            if k <= 3 or len(t_old) < k or len(t_new) < k:
                continue
            if t_old[-k:] == t_new[-k:]:
                return
        self._last_flushed = text
        await self._s.ui({"type": "transcript", "role": "assistant", "text": text,
                          **self._s.turn_ts_fields()})
        user = self._pending_user
        self._pending_user = ""
        if dashboard is not None:
            asyncio.create_task(dashboard.record(self._s.thread_id, user or "(continued)", text))


# ------------------------------------------------------------ session -------
class VoiceSession:
    def __init__(self, surface: str, connection: Optional[SmallWebRTCConnection],
                 transport_pair: tuple | None = None):
        self.surface = surface
        self.connection = connection
        self.pc_id = getattr(connection, "pc_id", None) or f"{surface}-{uuid.uuid4().hex[:8]}"
        self.thread_id = "vg-" + uuid.uuid4().hex[:12]
        self.started = time.time()
        self.metrics: Dict[str, Any] = {"turns": 0, "last_latency_ms": None,
                                        "avg_latency_ms": None, "interruptions": 0,
                                        "breakdown": None}
        self._lat: List[float] = []
        self._user_stopped_at: Optional[float] = None
        self._audio_in_frames = 0
        self._audio_out_frames = 0
        self._audio_summary_done = False
        self.runner: Optional[PipelineRunner] = None
        self.task: Optional[PipelineTask] = None
        self.transport: Optional[SmallWebRTCTransport] = None
        self._transport_pair = transport_pair
        self._out = None
        self.brain_label = ""
        self.realtime = brain_mod.is_realtime()      # decided per call (credits probe, voice.env)
        self.closed = False
        self.stop_reason: Optional[str] = None       # who stopped this session (forensics)

    # ---- messages to the client ---------------------------------------------
    async def ui(self, message: Dict[str, Any]) -> None:
        if self._out is None:
            return
        try:
            message.setdefault("ts", round(time.time(), 3))
            await self._out.send_message(OutputTransportMessageUrgentFrame(message=message))
        except Exception as exc:  # noqa: BLE001 - a UI hint must never break audio
            log.debug("ui send failed: {}", exc)

    async def status(self, state: str, label: str) -> None:
        await self.ui({"type": "state", "state": "working" if state == "working" else "idle",
                       "label": label})

    def mark_user_stopped(self) -> None:
        self._user_stopped_at = time.time()

    def turn_ts_fields(self) -> Dict[str, Any]:
        """Per-turn timestamps for data-channel transcript messages (see
        docs/API.md "Voice gateway data channel"). Backward-compatible ADDITIVE
        fields: clients written before them ignore unknown keys. `ts` on every
        message is the transport send time; `ts_turn`/`ts_iso` are stamped when
        the TURN completed (final text known), so a turn that finished before
        the transport was ready still carries its real time."""
        ts = _turn_ts()
        return {"ts_turn": ts, "ts_iso": _turn_iso(ts)}

    # ---- audio verification counters (2026-09-30 round 2) ------------------
    # "Verified end-to-end" from turn latency is NOT proof the phone played
    # audio (bug B: gateway spoke, Enrique heard silence on push-answer).
    # These counters + the disconnect summary give a hard signal: if audio_in
    # stayed 0 the mic never reached us; if audio_out is thousands of frames
    # but he heard nothing, the fault is device-side playout.
    def count_audio_in(self, frame) -> None:
        self._audio_in_frames += 1
        # First inbound audio proves the phone's mic/capture path works.
        if self._audio_in_frames == 1:
            log.info("audio-in first frame pc={} surface={} (mic confirmed)", self.pc_id, self.surface)

    def count_audio_out(self, frame) -> None:
        self._audio_out_frames += 1
        if self._audio_out_frames == 1:
            log.info("audio-out first frame pc={} surface={} (bot audio being sent)", self.pc_id, self.surface)

    def _log_audio_summary(self) -> None:
        log.info("audio summary pc={} surface={} in={} frames out={} frames "
                 "(out>0 + he heard nothing = device playout fault; in=0 = device capture fault)",
                 self.pc_id, self.surface, self._audio_in_frames, self._audio_out_frames)

    def audio_summary(self) -> Dict[str, Any]:
        """Post-call audio evidence (2026-10-17): the same numbers the journal
        'audio summary' line carries, as a structured record. in>0 = the
        phone's MIC reached us; out>0 = bot audio was SENT (out>0 + he heard
        nothing = device playout fault; in=0 = capture fault)."""
        return {"pc_id": self.pc_id, "surface": self.surface,
                "thread": self.thread_id,
                "audio_in_frames": self._audio_in_frames,
                "audio_out_frames": self._audio_out_frames,
                "turns": self.metrics.get("turns"),
                "avg_latency_ms": self.metrics.get("avg_latency_ms"),
                "duration_s": round(time.time() - self.started, 1),
                "stop_reason": self.stop_reason}

    # ---- lifecycle --------------------------------------------------------
    async def start(self) -> None:
        assert dashboard is not None
        ctx = await dashboard.context()
        system_prompt = brain_mod.build_system_prompt(ctx)
        tools = brain_mod.Tools(dashboard, self.thread_id, self.status,
                                task_getter=lambda: self.task,
                                inject=self.inject_user_text, ui=self.ui,
                                ender=self.stop)
        tools_schema = await tools.build()
        self.tools = tools

        llm, self.brain_label = brain_mod.make_llm(system_prompt)
        self.llm = llm
        if not self.realtime:
            asyncio.create_task(brain_mod.warm_prefix(system_prompt, tools_schema))
        # Realtime: the persona is the session's `instructions`; no system item in
        # the conversation (it would be a weaker duplicate). Cascade: system message.
        context = LLMContext(
            messages=([] if self.realtime else [{"role": "system", "content": system_prompt}]),
            tools=tools_schema)
        if self.realtime:
            # OpenAI Realtime does VAD / semantic end-of-turn / interruption on
            # its side; the aggregator just follows the service's turn signals.
            agg = LLMContextAggregatorPair(
                context,
                user_params=LLMUserAggregatorParams(
                    user_turn_strategies=ExternalUserTurnStrategies()),
                realtime_service_mode=True,
            )
            in_rate = 24000
        else:
            # Pipecat 1.10: VAD + turn-taking live on the user aggregator (the old
            # TransportParams.vad_analyzer field no longer exists and is silently
            # ignored). Default stop strategy = smart-turn v3 (semantic end-of-turn).
            agg = LLMContextAggregatorPair(
                context,
                user_params=LLMUserAggregatorParams(
                    vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=VAD_STOP_SECS)),
                    user_turn_stop_timeout=4.0),
            )
            in_rate = 16000
        self._in_rate = in_rate

        def _middle():
            # realtime: the model hears and speaks; cascade: STT -> LLM -> TTS
            return ([agg.user(), llm] if self.realtime
                    else [get_stt(), agg.user(), llm, get_tts()])

        if self._transport_pair is not None:
            in_tp, out_tp = self._transport_pair
            self._out = out_tp
            pipeline = Pipeline([in_tp, *_middle(), out_tp, agg.assistant()])
        else:
            transport = SmallWebRTCTransport(
                webrtc_connection=self.connection,
                params=TransportParams(
                    audio_in_enabled=True,
                    audio_in_filter=RNNoiseFilter(),
                    audio_out_enabled=True,
                    audio_in_sample_rate=in_rate,
                    audio_out_sample_rate=24000,
                ),
            )
            self.transport = transport
            self._out = transport.output()
            pipeline = Pipeline([transport.input(), *_middle(), transport.output(),
                                 agg.assistant()])

            @transport.event_handler("on_client_connected")
            async def _connected(_tp, _conn):
                self._connected_at = time.time()
                log.info("client connected pc={} thread={}", self.pc_id, self.thread_id)
                await self.ui({"type": "hello", "thread": self.thread_id,
                               "brain": self.brain_label,
                               "tts": "openai-realtime" if self.realtime else ELEVEN_MODEL,
                               "stt": "openai-realtime" if self.realtime else f"whisper-{WHISPER_MODEL}",
                               "surface": self.surface})
                g = greeting()
                if g and self.task:
                    if self.realtime:
                        # Same dead-frame issue as _greet_later: speak the
                        # greeting via direct client events.
                        await self.inject_user_text(
                            "(Automatic notice: the call just connected. Say exactly "
                            + repr(g) + " and nothing else.)")
                    else:
                        await self.task.queue_frame(TTSSpeakFrame(g))

            @transport.event_handler("on_client_disconnected")
            async def _disconnected(_tp, _conn):
                log.info("client disconnected pc={}", self.pc_id)
                # Tag the cause BEFORE stop(): the harness (T6) reads
                # stop_reason to distinguish "client/ICE went away" from a
                # genuine unexplained server-side hangup. Consent-expiry /
                # ICE death lands here.
                if not self.stop_reason:
                    self.stop_reason = "client-disconnect"
                await self.stop()

            @transport.event_handler("on_app_message")
            async def _app_message(_tp, message, _sender):
                await self._handle_app_message(message)

        latency = UserBotLatencyObserver()

        @latency.event_handler("on_latency_measured")
        async def _on_latency(_obs, secs: float):
            ms = secs * 1000
            self._lat.append(ms)
            self.metrics["turns"] = len(self._lat)
            self.metrics["last_latency_ms"] = round(ms)
            self.metrics["avg_latency_ms"] = round(sum(self._lat) / len(self._lat))
            log.info("voice-to-voice latency {:.0f} ms (turn {})", ms, len(self._lat))
            await self.ui({"type": "metrics", "latency_ms": round(ms),
                           "avg_ms": self.metrics["avg_latency_ms"], "turn": len(self._lat)})
            if record_turn:
                record_turn(self.surface, total_ms=ms, ok=1, note=self.brain_label)

        @latency.event_handler("on_latency_breakdown")
        async def _on_breakdown(_obs, breakdown):
            try:
                self.metrics["breakdown"] = breakdown.model_dump() if hasattr(breakdown, "model_dump") else str(breakdown)
            except Exception:  # noqa: BLE001
                pass

        self._ui_observer = UIObserver(self)
        self.task = PipelineTask(
            pipeline,
            params=PipelineParams(allow_interruptions=True, enable_metrics=True,
                                  audio_in_sample_rate=self._in_rate,
                                  audio_out_sample_rate=24000),
            observers=[self._ui_observer, latency, AudioCounterObserver(self)],
        )
        self.runner = PipelineRunner(handle_sigint=False)
        asyncio.create_task(self._run())
        asyncio.create_task(self._presence_loop())
        if self._transport_pair is not None:
            # Discord: no "client connected" event — greet once the pipeline is up.
            self._connected_at = time.time()
            asyncio.create_task(self._greet_later(1.5))
        log.info("session started surface={} pc={} thread={} brain={}",
                 self.surface, self.pc_id, self.thread_id, self.brain_label)

    async def _greet_later(self, delay: float) -> None:
        await asyncio.sleep(delay)
        g = greeting()
        if not g or not self.task or self.closed:
            return
        if self.realtime:
            # LLMMessagesAppendFrame is a no-op on the realtime service (its
            # handler is literally `logger.error("NEED TO IMPLEMENT")`), so the
            # Discord greeting never fired — he sat in silence and had to speak
            # first. Inject a user-role notice + response.create directly, same
            # as inject_user_text does.
            await self.inject_user_text(
                "(Automatic notice: the call just connected. Say exactly "
                + repr(g) + " and nothing else.)")
        else:
            await self.task.queue_frame(TTSSpeakFrame(g))

    async def _presence_loop(self) -> None:
        """Heartbeat to the engine: he is on the line for this thread."""
        while not self.closed and dashboard is not None:
            await dashboard.presence(self.thread_id)
            # ask_jarvis works on a sibling engine thread (brain.agent_thread_id);
            # the engine's is_live() must be true there too or every result goes
            # to WhatsApp as "he walked away".
            await dashboard.presence(brain_mod.agent_thread_id(self.thread_id))
            await asyncio.sleep(3.0)

    async def _run(self) -> None:
        try:
            await self.runner.run(self.task)
        except Exception as exc:  # noqa: BLE001
            log.error("pipeline ended with error: {}", exc)
            # Tell the client the session died (native iOS + web page both
            # consume state:error) — otherwise a mid-call crash leaves the
            # phone connected to a dead pipeline with no audio and no hint.
            try:
                await self.ui({"type": "state", "state": "error",
                               "label": f"session error: {exc}"[:120]})
            except Exception:  # noqa: BLE001
                pass
        finally:
            self.closed = True

    async def _handle_app_message(self, message: Any) -> None:
        if not isinstance(message, dict):
            return
        kind = message.get("type")
        if kind == "say":
            await self.say(str(message.get("text") or ""))
        elif kind == "interrupt" and self.task:
            await self.interrupt()
        elif kind == "mic":
            pass  # mic mute is handled client-side (track.enabled)

    async def inject_user_text(self, text: str) -> None:
        """Put a user-role message into the conversation and have the model
        respond. Cascade: an LLMMessagesAppendFrame through the aggregator.
        Realtime: Pipecat 1.10's OpenAIRealtimeLLMService leaves message-append
        unimplemented (a context update only forwards tool results), so send
        the client events directly: conversation.item.create + response.create.

        Reliability contract (2026-09-30): an injection is NEVER silently
        dropped. The old code bailed with `realtime inject skipped: websocket
        not ready` when the realtime socket hadn't finished its session
        bootstrap — the greeting/notice was lost on exactly those calls.
        Now we wait (bounded) for the socket, and retry after short
        reconnect blips. If the session closes first, we log a loud error.
        """
        text = (text or "").strip()
        if not text or not self.task:
            return
        llm = getattr(self, "llm", None)
        if self.realtime:
            from pipecat.services.openai.realtime import events as rt
            item = rt.ConversationItem(
                type="message", role="user",
                content=[rt.ItemContent(type="input_text", text=text)])

            async def _rt_send() -> bool:
                sock = getattr(llm, "_websocket", None)
                if sock is None:
                    return False
                # Right after connect the realtime session is still receiving
                # its instructions + greeting; a message injected in that
                # window got a persona-less "Hey there! happy to help" (seen
                # in testing). Wait that window out before the first send.
                since = time.time() - getattr(self, "_connected_at", 0.0)
                if since < 3.5:
                    await asyncio.sleep(3.5 - since)
                await llm.send_client_event(rt.ConversationItemCreateEvent(item=item))
                await llm.send_client_event(rt.ResponseCreateEvent())
                return True

            # Bounded wait+retry: 10s for the initial bootstrap, then up to 3
            # short retries for a mid-call reconnect (total ceiling ~16s).
            deadline = time.time() + 10.0
            while True:
                try:
                    if await _rt_send():
                        return
                except Exception as exc:  # noqa: BLE001 - fall through to retry
                    log.warning("realtime inject attempt failed: {}", exc)
                if self.closed or time.time() > deadline:
                    log.error("realtime inject DROPPED (websocket never ready, "
                              "session closed={}) — text: {!r}", self.closed, text[:120])
                    return
                await asyncio.sleep(1.0)
                llm = getattr(self, "llm", None)
        await self.task.queue_frame(
            LLMMessagesAppendFrame(messages=[{"role": "user", "content": text}], run_llm=True))

    async def interrupt(self) -> None:
        """Tap-to-interrupt from the page: cancel the response being generated
        and flush whatever audio is still queued for playback."""
        llm = getattr(self, "llm", None)
        if self.realtime and llm is not None and getattr(llm, "_websocket", None):
            try:
                from pipecat.services.openai.realtime import events as rt
                await llm.send_client_event(rt.ResponseCancelEvent())
            except Exception as exc:  # noqa: BLE001
                log.debug("response.cancel failed: {}", exc)
        try:
            if self.task:
                await self.task.queue_frame(InterruptionFrame())
        except Exception as exc:  # noqa: BLE001
            log.debug("interruption frame failed: {}", exc)
        await self.ui({"type": "state", "state": "listening"})

    async def say(self, text: str) -> None:
        """Inject typed text as if he had said it (page text box, tests)."""
        text = (text or "").strip()
        if not text or not self.task:
            return
        # A typed line is a finished turn too — start the latency clock here so
        # the orb and metrics.db get numbers for typed input as well as speech.
        self.mark_user_stopped()
        await self.ui({"type": "transcript", "role": "user", "text": text,
                       "typed": True, **self.turn_ts_fields()})
        obs = getattr(self, "_ui_observer", None)
        if obs is not None:
            obs._pending_user = (obs._pending_user + " " + text).strip()
        await self.inject_user_text(text)

    async def stop(self) -> None:
        if self.closed:
            return
        self.closed = True
        if not self.stop_reason:
            # end_call stamps the TOOLS object (brain.py) — pick it up here so
            # the session record says who ended the call.
            tools_reason = getattr(getattr(self, "tools", None), "stop_reason", None)
            self.stop_reason = tools_reason or "closed"
        self.metrics["stop_reason"] = self.stop_reason
        # Audio verification summary (bug B forensics) — exactly once, even if
        # stop() is called from several paths (guard, hangup, disconnect).
        if not self._audio_summary_done:
            self._audio_summary_done = True
            self._log_audio_summary()
            # Durable post-call evidence chain (2026-10-17): the same summary,
            # (1) pushed ONCE to the client over the data channel before the
            # pipeline is cancelled — the app (build 68+) stamps its call log
            # from this message ({type: audio_summary, audio_in_frames,
            # audio_out_frames}); (2) recorded into the dashboard call record
            # (same /record channel transcript turns use), so the pair
            # [gateway journal line, call record] is retrievable after the PC
            # is gone.
            summary = self.audio_summary()
            try:
                await self.ui({"type": "audio_summary", **summary})
            except Exception as exc:  # noqa: BLE001 - evidence must never block hangup
                log.debug("audio summary push failed: {}", exc)
            if dashboard is not None:
                try:
                    await dashboard.record(
                        self.thread_id, "(audio summary)",
                        _json.dumps(summary, separators=(",", ":")))
                except Exception as exc:  # noqa: BLE001
                    log.debug("audio summary record failed: {}", exc)
        try:
            if self.task:
                await self.task.cancel()
        except Exception as exc:  # noqa: BLE001
            log.debug("task cancel: {}", exc)
        if record_turn:
            record_turn(self.surface, ok=1, note="session_closed",
                        total_ms=self.metrics.get("avg_latency_ms"))
        # Detached on purpose: the pipeline is already cancelled, so this cannot
        # delay hanging up, and the process outlives the call.
        try:
            asyncio.create_task(self._write_call_recap())
        except RuntimeError:            # no running loop (shutdown) - skip it
            pass

    async def _write_call_recap(self) -> None:
        """Summarise this call into the knowledge base so the NEXT one knows it.

        Cheap on purpose: one GLM-flash call on Fireworks, 25 s ceiling, and it
        only runs when there was a real conversation to remember.
        """
        try:
            import httpx as _httpx
            from pathlib import Path as _Path
            calls_dir = _Path(os.environ.get("VOICE_CALLS_DIR",
                                             "/root/.hermes/voice_conversations"))
            src = calls_dir / f"{self.thread_id}.jsonl"
            lines = []
            users = 0
            try:
                for raw in src.read_text(encoding="utf-8").splitlines():
                    try:
                        d = _json.loads(raw)
                    except ValueError:
                        continue
                    role = (d.get("role") or "").strip()
                    text = " ".join(str(d.get("text") or d.get("content") or "").split())
                    if not text or role not in ("user", "assistant"):
                        continue
                    if role == "user":
                        users += 1
                    lines.append(("Enrique: " if role == "user" else "JARVIS: ") + text[:400])
            except OSError:
                return
            if users < 2 or len(lines) < 3:
                return                      # nothing worth remembering
            blob = " ".join(lines).lower()
            # The overnight regression suite asks these verbatim. Its chatter must
            # never be written into his memory: it would push his real calls out of
            # the trimmed file. Any ONE of the unmistakable probes is enough; the
            # softer ones need two, since he could plausibly say them himself.
            if any(m in blob for m in (
                    "how much free disk space your own linux server",
                    "what's the capital of spain",
                    "who are you, and can you change your own voice")):
                return
            soft = sum(1 for m in (
                "hold on, give me five seconds of silence",
                "and who is stu on the team",
                "how many automations do i have running right now",
                "hold on, quiet please",
                "quiet for a moment please",
                "stop talking.",
                "let's start a new conversation") if m in blob)
            if soft >= 2:
                return                      # the regression suite talking to itself
            transcript = chr(10).join(lines)[-6000:]

            key = os.environ.get("FIREWORKS_API_KEY", "")
            if not key:
                return
            model = brain_mod.cfg("VOICE_FIREWORKS_MODEL",
                                  "accounts/fireworks/models/glm-5p3-flash")
            ask = ("Summarise this voice call for JARVIS's own memory, so the next call knows what "
                   "happened. At most 5 short lines, no pleasantries, no preamble. Cover only: what "
                   "Enrique asked for, what was decided, anything still open, and any durable fact "
                   "HE stated about himself or his work. Attribute anything JARVIS claimed as "
                   "(JARVIS said) rather than as fact, since it may have been wrong. "
                   "If the call was trivial, reply with the "
                   "single word SKIP.\n\n" + transcript)
            async with _httpx.AsyncClient(timeout=25.0) as client:
                r = await client.post(
                    "https://api.fireworks.ai/inference/v1/chat/completions",
                    headers={"Authorization": f"Bearer {key}"},
                    json={"model": model, # 1200 not 260: glm-flash is a thinking model and spent a small budget
                          # entirely on reasoning tokens, returning an EMPTY summary.
                          "max_tokens": 1200, "temperature": 0.2,
                          "messages": [{"role": "user", "content": ask}]})
                r.raise_for_status()
                out = r.json()["choices"][0]["message"]["content"]
            summary = " ".join(str(out or "").split())
            if not summary or summary.upper().startswith("SKIP"):
                return
            kb = _Path(os.environ.get("VOICE_KB_DIR", "/root/.hermes/jarvis/voice_kb"))
            kb.mkdir(parents=True, exist_ok=True)
            path = kb / "calls.md"
            head = "# Recent calls\n<!-- written by the gateway when a call ends (A4). Newest last. This records what was SAID on a call, not what is true: where it conflicts with the other knowledge-base files, they win. -->\n"
            existing = path.read_text(encoding="utf-8") if path.exists() else head
            stamp = datetime.now(brain_mod.TZ).strftime("%Y-%m-%d %H:%M")
            entry = f"\n## {stamp} ({users} of his turns)\n{summary[:1200]}\n"
            text = existing.rstrip() + chr(10) + entry
            if len(text) > 9000:            # keep the newest entries only
                parts = text.split("\n## ")
                text = parts[0] + "\n## " + "\n## ".join(parts[-6:])
            path.write_text(text, encoding="utf-8")
            log.info("call recap written for {} ({} chars)", self.thread_id, len(summary))
        except Exception as exc:  # noqa: BLE001 - a recap must never break teardown
            log.debug("call recap skipped: {}", exc)

    def snapshot(self) -> Dict[str, Any]:
        return {"pc_id": self.pc_id, "surface": self.surface, "thread": self.thread_id,
                "brain": self.brain_label, "age_s": round(time.time() - self.started),
                "closed": self.closed, "metrics": self.metrics,
                "stop_reason": self.stop_reason,
                "jobs": getattr(getattr(self, "tools", None), "jobs", {})}


class VoiceSessionManager:
    def __init__(self):
        self._sessions: Dict[str, VoiceSession] = {}

    async def start(self, surface: str, connection: SmallWebRTCConnection) -> VoiceSession:
        session = VoiceSession(surface, connection)
        self._sessions[session.pc_id] = session
        await session.start()
        self._prune()
        return session

    async def start_custom(self, surface: str, key: str, transport_pair: tuple) -> VoiceSession:
        session = VoiceSession(surface, None, transport_pair=transport_pair)
        session.pc_id = key
        self._sessions[key] = session
        await session.start()
        return session

    def get(self, pc_id: Optional[str]) -> Optional[VoiceSession]:
        if pc_id and pc_id in self._sessions:
            return self._sessions[pc_id]
        live = [s for s in self._sessions.values() if not s.closed]
        return live[-1] if live else None

    def list(self) -> List[Dict[str, Any]]:
        return [s.snapshot() for s in self._sessions.values()]

    def _prune(self) -> None:
        dead = [k for k, s in self._sessions.items() if s.closed and time.time() - s.started > 600]
        for k in dead:
            self._sessions.pop(k, None)

    async def close_all(self) -> None:
        for s in list(self._sessions.values()):
            try:
                await s.stop()
            except Exception as exc:  # noqa: BLE001
                log.warning("session close error: {}", exc)
        self._sessions.clear()
