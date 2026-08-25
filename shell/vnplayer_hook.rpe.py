# A Ren'Py Extension, loaded by the engine for EVERY game it starts.
#
# The problem this solves: `config.periodic_callbacks` is how the shell drains commands
# from the native side, and the shell project registers it in its own `script.rpy`. An
# imported game does not load our script.rpy -- it loads its own -- so the moment a real
# game starts, the command channel goes deaf. Nothing could quit back to the library, and
# nothing could tell Swift the game had actually started.
#
# `renpy/main.py:350-362` reads `predefined_searchpath()` (which we define, in main.py)
# and then scans `config.renpy_base`, every searchpath entry, and `<gamedir>/libs` for
# `.rpe` and `.rpe.py` files, exec'ing each one. `config.renpy_base` is our base
# directory -- the one holding main.py and vnshell/ -- so a file dropped there is loaded
# for every game, without ever touching the game's own directory.
#
# That matters beyond tidiness: imported games are untrusted third-party content, and
# writing into their tree would both risk collisions and make our own code look like part
# of the game to anyone reading it.
#
# It runs during early init, after `config` has been rebuilt for this restart, which is
# exactly when a per-game registration needs to happen.

import renpy  # type: ignore


def _attach():
    try:
        from vnshell import lifecycle
    except ImportError:
        # The shell layer is missing. Nothing here can work, and raising would abort the
        # game's startup entirely -- a game that runs without the overlay is far better
        # than one that will not start.
        return

    lifecycle.attach_to_game()


_attach()
