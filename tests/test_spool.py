# tests/test_spool.py
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.transports import SpoolEmitter, SpoolTransport  # noqa: E402


class SpoolTransportTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.directory = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def write_message(self, name, payload):
        with open(os.path.join(self.directory, name), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def test_reads_and_consumes(self):
        self.write_message("0001.json", {"command": "launch"})
        transport = SpoolTransport(self.directory)

        self.assertEqual(transport.receive(), [{"command": "launch"}])
        # Not consuming would replay the command every frame, relaunching forever.
        self.assertEqual(transport.receive(), [])

    def test_reads_in_name_order(self):
        for index in range(10):
            self.write_message("%04d.json" % index, {"n": index})

        got = [command["n"] for command in SpoolTransport(self.directory).receive()]
        self.assertEqual(got, list(range(10)))

    def test_ignores_temp_files(self):
        # The whole point of the design. A half-written message lives under .tmp until
        # the writer renames it, so the reader must never look at .tmp at all.
        with open(os.path.join(self.directory, "0001.json.tmp"), "w") as f:
            f.write('{"command": "lau')

        self.assertEqual(SpoolTransport(self.directory).receive(), [])
        self.assertTrue(os.path.exists(os.path.join(self.directory, "0001.json.tmp")))

    def test_nothing_written_during_a_read_is_lost(self):
        # The failure this replaced. FileTransport reads the whole file then deletes it,
        # so a command arriving in between is destroyed unread. Here each message is its
        # own file and a write during a read is simply seen by the next one.
        transport = SpoolTransport(self.directory)
        self.write_message("0001.json", {"n": 1})

        first = transport.receive()
        self.write_message("0002.json", {"n": 2})
        second = transport.receive()

        self.assertEqual([c["n"] for c in first], [1])
        self.assertEqual([c["n"] for c in second], [2])

    def test_unparseable_message_is_dropped_not_retried(self):
        with open(os.path.join(self.directory, "0001.json"), "w") as f:
            f.write("not json")

        transport = SpoolTransport(self.directory)
        self.assertEqual(transport.receive(), [])
        self.assertEqual(transport.receive(), [])
        self.assertFalse(os.path.exists(os.path.join(self.directory, "0001.json")))

    def test_non_object_json_is_ignored(self):
        self.write_message("0001.json", ["not", "an", "object"])
        self.assertEqual(SpoolTransport(self.directory).receive(), [])

    def test_missing_directory_is_not_an_error(self):
        # Polled every frame from startup, possibly before anything has created it.
        transport = SpoolTransport(os.path.join(self.directory, "nope"))
        self.assertEqual(transport.receive(), [])


class SpoolEmitterTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.directory = os.path.join(self._tmp.name, "Events")

    def tearDown(self):
        self._tmp.cleanup()

    def test_emit_then_read_back(self):
        emitter = SpoolEmitter(self.directory)
        self.assertTrue(emitter.emit({"event": "gameReady", "gameId": "mygame"}))

        received = SpoolTransport(self.directory).receive()
        self.assertEqual(received, [{"event": "gameReady", "gameId": "mygame"}])

    def test_leaves_no_temp_file_behind(self):
        SpoolEmitter(self.directory).emit({"event": "gameReady"})
        leftovers = [n for n in os.listdir(self.directory) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_emits_in_order(self):
        emitter = SpoolEmitter(self.directory)
        for index in range(5):
            emitter.emit({"n": index})

        got = [e["n"] for e in SpoolTransport(self.directory).receive()]
        self.assertEqual(got, list(range(5)))

    def test_unwritable_directory_returns_false_rather_than_raising(self):
        # An event that cannot be written must not take the engine down with it: the
        # game is more important than the notification that it started.
        emitter = SpoolEmitter("")
        self.assertFalse(emitter.emit({"event": "gameReady"}))

    def test_round_trip_survives_non_ascii(self):
        emitter = SpoolEmitter(self.directory)
        emitter.emit({"event": "gameReady", "gameId": "月に寄りそう"})

        received = SpoolTransport(self.directory).receive()
        self.assertEqual(received[0]["gameId"], "月に寄りそう")


if __name__ == "__main__":
    unittest.main()
