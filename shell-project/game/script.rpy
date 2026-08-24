init python:
    def _vnplayer_tick():
        import vnshell.lifecycle
        vnshell.lifecycle.tick()

    config.periodic_callbacks.append(_vnplayer_tick)

label start:
    scene black
    jump idle

label idle:
    # A hard pause ignores clicks, so this never advances on stray input — the only
    # thing that ends it is the periodic callback raising UtterRestartException when
    # a game is selected. Deliberately no say statement: an empty one would block
    # waiting for a tap before the idle loop was ever reached.
    $ renpy.pause(3600.0, hard=True)
    jump idle
