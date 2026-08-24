init python:
    import sys
    import os

    def _vnplayer_tick():
        import vnshell.lifecycle
        vnshell.lifecycle.tick()

        # SPIKE: drain anything Swift wrote, via the same transport the control proved.
        transport = getattr(store, "vnspike_transport", None)
        if transport is None:
            return
        try:
            for cmd in transport.receive():
                store.vnspike_received += 1
                store.vnspike_last = repr(cmd)
                renpy.restart_interaction()
        except Exception as e:
            store.vnspike_last = "drain failed: %s" % type(e).__name__

    config.periodic_callbacks.append(_vnplayer_tick)

    def vnplayer_probe():
        """Collect proof-of-life facts once, at startup.

        This exists because the shell screen's success state and its failure state
        used to be identical: a black screen. On a device with no console that made
        it impossible to tell a running engine from one that died after the splash.
        Rendering these facts turns "it is black" into a discriminating observation.
        """

        import renpy

        lines = []
        lines.append("Ren'Py " + renpy.version_only)
        lines.append("Python %d.%d.%d" % sys.version_info[:3])
        lines.append("platform: " + sys.platform)
        lines.append("basedir: " + str(renpy.config.basedir))
        lines.append("logdir: " + str(renpy.config.logdir))

        # Whether Ren'Py can write log.txt at all. On iOS the bundle is read-only,
        # so this is expected to say NO until path_to_logdir points somewhere else.
        logdir = renpy.config.logdir
        try:
            probe = os.path.join(logdir, "vnplayer-write-probe.tmp")
            with open(probe, "w") as f:
                f.write("ok")
            os.unlink(probe)
            lines.append("logdir writable: YES")
        except Exception as e:
            lines.append("logdir writable: NO (%s)" % type(e).__name__)

        # Where a writable per-app directory would be, for comparison.
        try:
            home = os.path.expanduser("~")
            lines.append("home: " + str(home))
            docs = os.path.join(home, "Documents")
            lines.append("Documents exists: %s" % os.path.isdir(docs))
        except Exception as e:
            lines.append("home: unavailable (%s)" % type(e).__name__)

        # Proof the shell package itself imported, not just Ren'Py.
        try:
            import vnshell
            import vnshell.lifecycle
            lines.append("vnshell: imported OK")
        except Exception as e:
            lines.append("vnshell: FAILED (%s: %s)" % (type(e).__name__, e))

        # --- SPIKE: the file mailbox, using Milestone A's own FileTransport ---
        #
        # ctypes.CDLL(None) is dead on this platform (device-verified, with a control:
        # even Py_Initialize is unresolvable). And a C extension module cannot be built,
        # because neither renios nor the SDK ships Python.h or a pyconfig.h matching the
        # prebuilt libpython3.12.a.
        #
        # So the mailbox substrate is a file in Documents -- which is what
        # vnshell.transports.FileTransport already does, and it is already tested.
        try:
            docs = os.path.join(os.path.expanduser("~"), "Documents")
            store.vnspike_cmd_path = os.path.join(docs, "vnplayer-commands.jsonl")
            lines.append("mailbox: %s" % store.vnspike_cmd_path)

            # CONTROL: write a line ourselves and read it back through the same
            # transport the overlay will use. If this fails, nothing downstream means
            # anything -- and we learn it here rather than blaming Swift.
            from vnshell.transports import FileTransport
            probe = FileTransport(store.vnspike_cmd_path)
            with open(store.vnspike_cmd_path, "w") as f:
                f.write('{"command": "self-test"}\n')
            got = probe.receive()
            ok = len(got) == 1 and got[0].get("command") == "self-test"
            lines.append("mailbox control: %s (wrote 1, read %d)"
                         % ("OK" if ok else "FAILED", len(got)))
            store.vnspike_transport = probe if ok else None
        except Exception as e:
            lines.append("mailbox control: FAILED (%s: %s)" % (type(e).__name__, e))
            store.vnspike_transport = None

        return lines


default vnplayer_facts = []
default vnplayer_seconds = 0
default vnspike_received = 0
default vnspike_last = "(nothing yet)"


screen vnplayer_shell():
    zorder 100

    # If this counter advances, the interaction loop is live, not merely painted once.
    timer 1.0 action SetVariable("vnplayer_seconds", vnplayer_seconds + 1) repeat True

    frame:
        xalign 0.5
        yalign 0.5
        xpadding 40
        ypadding 40

        vbox:
            spacing 10

            text "VNPlayer shell is running" size 42
            text "alive for [vnplayer_seconds]s" size 28

            null height 10

            for line in vnplayer_facts:
                text "[line]" size 20

            null height 6
            text "from Swift: [vnspike_received] received" size 22
            text "last: [vnspike_last]" size 18


label start:
    scene black
    $ vnplayer_facts = vnplayer_probe()
    show screen vnplayer_shell
    jump idle


label idle:
    # A hard pause ignores clicks, so this never advances on stray input — the only
    # thing that ends it is the periodic callback raising UtterRestartException when
    # a game is selected. Deliberately no say statement: an empty one would block
    # waiting for a tap before the idle loop was ever reached.
    $ renpy.pause(3600.0, hard=True)
    jump idle
