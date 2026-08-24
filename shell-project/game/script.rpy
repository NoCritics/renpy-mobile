init python:
    import sys
    import os

    def _vnplayer_tick():
        import vnshell.lifecycle
        vnshell.lifecycle.tick()

        # SPIKE: drain anything Swift posted, and surface it on screen.
        lib = getattr(store, "vnspike_lib", None)
        if lib is None:
            return
        try:
            import ctypes
            cmd = ctypes.c_int32()
            buf = ctypes.create_string_buffer(512)
            while lib.vnbridge_poll(ctypes.byref(cmd), buf, ctypes.c_int32(512)) == 1:
                store.vnspike_received += 1
                store.vnspike_last = "cmd=%d %r" % (cmd.value, buf.value.decode("utf-8", "replace"))
                renpy.restart_interaction()
        except Exception as e:
            store.vnspike_last = "poll failed: %s" % type(e).__name__

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

        # --- SPIKE: WHICH symbols can dlsym actually find? ---
        # Py_Initialize is the control: it comes from the statically linked libpython
        # and must be present. If the control fails, the whole probe is meaningless --
        # that is the check that makes this an instrument rather than a guess.
        store.vnspike_lib = None
        try:
            import ctypes
            lib = ctypes.CDLL(None)
            for label, name in (("control Py_Initialize", "Py_Initialize"),
                                ("swift @_cdecl", "vnspike_ping"),
                                ("plain C", "vnbridge_ping")):
                try:
                    fn = getattr(lib, name)
                    fn.restype = ctypes.c_int
                    if name == "Py_Initialize":
                        lines.append("%s: FOUND (not called)" % label)
                    else:
                        lines.append("%s %s: FOUND -> 0x%04X" % (label, name, fn()))
                        store.vnspike_lib = lib
                except Exception as e:
                    lines.append("%s %s: %s" % (label, name, type(e).__name__))
        except Exception as e:
            lines.append("ctypes unavailable: %s: %s" % (type(e).__name__, e))

        # --- SPIKE: overlay, if any export seam worked ---
        if store.vnspike_lib is not None:
            try:
                install = store.vnspike_lib.vnspike_install_overlay
                install.restype = ctypes.c_int
                rc = install()
                meaning = {1: "installed", 2: "already", -1: "not main thread", -2: "no scene"}
                lines.append("swift overlay: rc=%d (%s)" % (rc, meaning.get(rc, "?")))
            except Exception as e:
                lines.append("swift overlay: %s: %s" % (type(e).__name__, e))

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
