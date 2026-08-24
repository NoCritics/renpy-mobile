init python:
    import os, sys, json

    def observe(game):
        import renpy.store as store
        gamedir = renpy.config.gamedir
        sys.path.insert(0, gamedir)
        import sentinel
        record = {
            "game": game,
            "sentinel_value": sentinel.VALUE,
            # Per-game init state, declared in each game's own options.rpy. If game B
            # ever reads "Sentinel A", init-time state survived the switch.
            #
            # Two earlier canary designs failed here and are worth not repeating.
            # style.default.font matched Ren'Py's own engine-wide default
            # (00style.rpy:139), so it reported bleed even on a clean reset.
            # style.default.size was set but never read back, because mutating a style
            # outside an init block requires style.rebuild() to take effect. config.name
            # needs no such ceremony: each game already declares its own.
            "config_name": str(renpy.config.name),
            "saves_dir": renpy.__main__.path_to_saves(gamedir),
            "leaked_store_var": getattr(store, "game_a_marker", None),
        }
        out = os.environ.get("VNPLAYER_OBSERVATIONS")
        if out:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")

label start:
    $ observe("B")
    scene expression "big.png"
    $ renpy.music.play("<silence 2.0>", channel="music", loop=True)
    $ renpy.save("cycle-marker")
    $ renpy.pause(0.2, hard=True)
    $ import vnshell.harness; vnshell.harness.advance()
    $ renpy.pause(3600.0, hard=True)
