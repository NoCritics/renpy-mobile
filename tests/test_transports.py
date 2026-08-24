import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.transports import FileTransport, NullTransport  # noqa: E402


class NullTransportTests(unittest.TestCase):
    def test_receives_nothing(self):
        self.assertEqual(NullTransport().receive(), [])


class FileTransportTests(unittest.TestCase):
    def test_missing_file_yields_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            t = FileTransport(os.path.join(d, "absent.jsonl"))
            self.assertEqual(t.receive(), [])

    def test_reads_and_consumes_commands(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cmd.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"name": "launch", "args": {"basedir": "/x"}}) + "\n")
                f.write(json.dumps({"name": "quitToLibrary", "args": {}}) + "\n")

            t = FileTransport(path)
            got = t.receive()

            self.assertEqual(len(got), 2)
            self.assertEqual(got[0]["name"], "launch")
            self.assertEqual(got[1]["name"], "quitToLibrary")

            # Consumed: a second poll must be empty, or every tick would replay them.
            self.assertEqual(t.receive(), [])

    def test_malformed_line_is_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cmd.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write("this is not json\n")
                f.write(json.dumps({"name": "quitToLibrary", "args": {}}) + "\n")

            got = FileTransport(path).receive()
            self.assertEqual([c["name"] for c in got], ["quitToLibrary"])


if __name__ == "__main__":
    unittest.main()
