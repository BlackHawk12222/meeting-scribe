"""Microphone capture with sounddevice (PortAudio)."""

from __future__ import annotations

import logging
import threading

import numpy as np

log = logging.getLogger("scribe")


class Recorder:
    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream = None
        self.sample_rate = 16000
        self.level = 0.0  # last chunk loudness 0..1, for the capsule

    def start(self) -> None:
        import sounddevice as sd

        with self._lock:
            self._chunks = []
        # Use the device's own rate; sherpa-onnx resamples to 16 kHz itself.
        self._stream = sd.InputStream(channels=1, dtype="float32", callback=self._callback, blocksize=0)
        self.sample_rate = int(self._stream.samplerate)
        self._stream.start()
        log.info("Recording at %d Hz", self.sample_rate)

    def _callback(self, indata, frames, time_info, status) -> None:  # PortAudio thread
        mono = indata[:, 0].copy()
        with self._lock:
            self._chunks.append(mono)
        self.level = float(min(1.0, np.sqrt(np.mean(mono * mono)) * 8)) if mono.size else 0.0

    def stop(self) -> np.ndarray:
        s, self._stream = self._stream, None
        if s is not None:
            try:
                s.stop()
            finally:
                s.close()
        with self._lock:
            audio = np.concatenate(self._chunks) if self._chunks else np.zeros(0, np.float32)
            self._chunks = []
        self.level = 0.0
        return audio

    @property
    def active(self) -> bool:
        return self._stream is not None
