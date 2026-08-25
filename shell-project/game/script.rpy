init python:
    import sys
    import os

    def _vnplayer_tick():
        # NOTE: lifecycle.tick() is NOT called here any more. vnplayer_hook.rpe.py
        # registers it for every game the engine loads, this shell project included, so
        # calling it here too would drain the command spool twice per frame. This
        # callback now carries only the shell project's own diagnostics.

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

        # Virtual vs physical size, because the device shows this screen CROPPED: the
        # top and bottom are cut off. Measured from the overlay screenshots, our own
        # UIKit control sits correctly centred in a 1280x591 screen while Ren'Py's
        # centred frame does not, which means Ren'Py's surface is taller than the
        # visible area rather than the screenshot being trimmed.
        #
        # If that is Ren'Py filling to width and overflowing height rather than
        # letterboxing, it costs every 16:9 game the top and bottom of its screen on a
        # 19.5:9 phone -- which is exactly where dialogue boxes and menus live. These
        # two numbers say which it is, and cost nothing to collect.
        try:
            vw = renpy.config.screen_width
            vh = renpy.config.screen_height
            pw, ph = renpy.get_physical_size()
            lines.append("virtual: %dx%d (%.3f)" % (vw, vh, float(vw) / vh))
            lines.append("physical: %dx%d (%.3f)" % (pw, ph, float(pw) / ph))
            # If these disagree, the engine is not preserving the game's aspect ratio.
            fits = abs((float(vw) / vh) - (float(pw) / ph)) < 0.01
            lines.append("aspect preserved: %s" % ("YES" if fits else "NO"))
        except Exception as e:
            lines.append("size probe failed: %s" % type(e).__name__)

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

        # The saves directory, which is the whole point of the path_to_saves change.
        # Before it, the device denied this on every launch:
        #   deny(1) file-write-create .../VNPlayer.app/base/game/saves
        savedir = getattr(renpy.config, "savedir", None)
        lines.append("savedir: " + str(savedir))
        try:
            if not savedir:
                raise RuntimeError("config.savedir is unset")
            probe = os.path.join(savedir, "vnplayer-save-probe.tmp")
            with open(probe, "w") as f:
                f.write("ok")
            os.unlink(probe)
            lines.append("savedir writable: YES")
        except Exception as e:
            lines.append("savedir writable: NO (%s)" % type(e).__name__)

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

            # Sizes reduced from 42/28/20: the list of facts has grown and the device
            # crops the top and bottom of this screen (see the virtual/physical probe
            # above). Smaller text is not a fix for the cropping -- it is so the facts
            # that diagnose the cropping are themselves readable.
            text "VNPlayer shell is running" size 30
            text "alive for [vnplayer_seconds]s" size 22

            null height 6

            for line in vnplayer_facts:
                text "[line]" size 16

            null height 4
            text "from Swift: [vnspike_received] received" size 18
            text "last: [vnspike_last]" size 14


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
