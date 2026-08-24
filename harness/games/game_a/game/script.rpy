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
            "font": str(style.default.font),
            "saves_dir": renpy.__main__.path_to_saves(gamedir),
            "leaked_store_var": getattr(store, "game_a_marker", None),
        }
        out = os.environ.get("VNPLAYER_OBSERVATIONS")
        if out:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")

label start:
    $ observe("A")
    $ style.default.font = "DejaVuSans.ttf"
    $ game_a_marker = "leaked"
    scene expression "big.png"
    $ renpy.music.play("<silence 2.0>", channel="music", loop=True)
    $ renpy.save("cycle-marker")
    $ renpy.pause(0.2, hard=True)
    $ import vnshell.harness; vnshell.harness.advance()
    $ renpy.pause(3600.0, hard=True)
