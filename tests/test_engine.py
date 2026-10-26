"""不加载大模型、不访问麦克风/剪贴板的回归测试。"""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import qwen_engine
import transcribe_qwen as worker


class EngineTests(unittest.TestCase):
    def test_empty_short_and_silent_audio_is_rejected(self):
        for samples in (np.zeros(0), np.ones(3999), np.zeros(16000)):
            self.assertFalse(qwen_engine.has_speech(samples))

    def test_no_speech_does_not_load_model_in_cli_mode(self):
        with patch.object(worker, "has_speech", return_value=False), \
             patch.object(worker, "QwenEngine") as engine:
            self.assertEqual(worker.recognize(np.zeros(16000)), ("", {"status": "no_speech"}))
            engine.assert_not_called()

    def test_pcm_format_and_incomplete_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "audio.pcm"
            path.write_bytes(b"\x00\x80\x00\x00\xff\x7f")
            np.testing.assert_allclose(qwen_engine.read_pcm(path), [-1, 0, 32767 / 32768])
            path.write_bytes(b"\x00")
            with self.assertRaises(ValueError):
                qwen_engine.read_pcm(path)

    def test_session_paths_and_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(worker, "ROOT", Path(tmp)):
            recordings = Path(tmp) / "recordings"
            recordings.mkdir()
            rid = str(uuid.uuid4())
            pcm, ready = recordings / (rid + ".pcm"), recordings / (rid + ".ready")
            worker.validate_session(pcm, ready, rid)
            for wrong_pcm, wrong_ready, wrong_id in (
                (Path(tmp) / pcm.name, ready, rid),
                (pcm, ready.with_name("wrong.ready"), rid),
                (pcm, ready, rid.upper()),
            ):
                with self.assertRaises(ValueError):
                    worker.validate_session(wrong_pcm, wrong_ready, wrong_id)
            pcm.symlink_to(Path(tmp) / "other.pcm")
            with self.assertRaises(ValueError):
                worker.validate_session(pcm, ready, rid)

    def test_ready_marker_must_match_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            ready = Path(tmp) / "ready"
            ready.write_text(json.dumps({"request_id": "old", "action": "transcribe"}))
            with self.assertRaises(ValueError):
                worker.wait_for_recording(ready, "new", 0)

    def check_preloaded(self, speech, failure=False):
        with tempfile.TemporaryDirectory() as tmp, patch.object(worker, "ROOT", Path(tmp)):
            recordings = Path(tmp) / "recordings"
            recordings.mkdir()
            rid = str(uuid.uuid4())
            pcm, ready = recordings / (rid + ".pcm"), recordings / (rid + ".ready")
            pcm.write_bytes(b"\x00\x00" * 16000)
            ready.write_text(json.dumps({"request_id": rid, "action": "transcribe"}))
            unrelated = recordings / "unrelated.pcm"
            unrelated.write_bytes(b"keep")
            args = SimpleNamespace(pcm=pcm, ready_file=ready, request_id=rid, language="auto")
            output = io.StringIO()
            with patch.object(worker, "QwenEngine") as factory, \
                 patch.object(worker, "has_speech", return_value=speech), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                engine = factory.return_value
                engine.load_seconds = 0
                engine.recognize.return_value = ("test", {})
                if failure:
                    engine.recognize.side_effect = RuntimeError("test failure")
                code = worker.run_preloaded(args)
                if not speech:
                    engine.recognize.assert_not_called()
            payload = json.loads(output.getvalue())
            self.assertEqual(payload["protocol"], 1)
            self.assertEqual(payload["request_id"], rid)
            self.assertFalse(pcm.exists())
            self.assertFalse(ready.exists())
            self.assertEqual(unrelated.read_bytes(), b"keep")
            return code, payload

    def test_preload_silence_has_no_text(self):
        code, payload = self.check_preloaded(False)
        self.assertEqual((code, payload["status"], payload["text"]), (0, "no_speech", ""))

    def test_preload_success_returns_only_new_text(self):
        code, payload = self.check_preloaded(True)
        self.assertEqual((code, payload["status"], payload["text"]), (0, "ok", "test"))

    def test_preload_failure_has_no_text_and_cleans_own_files(self):
        code, payload = self.check_preloaded(True, failure=True)
        self.assertEqual((code, payload["status"], payload["text"]), (1, "error", ""))


if __name__ == "__main__":
    unittest.main()
