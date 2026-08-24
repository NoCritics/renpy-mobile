init python:
    import sys
    import os

    def _vnplayer_tick():
        import vnshell.lifecycle
        vnshell.lifecycle.tick()

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

        return lines


default vnplayer_facts = []
default vnplayer_seconds = 0


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
