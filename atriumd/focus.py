"""Which session should you be looking at, and in what order do they sit?

Two different questions, and conflating them is a design error:

- **Order** is STABLE — sorted by name, never by urgency. It drives next/prev
  cycling and, later, where a project sits on a map or a shelf. A position that
  moves when something becomes urgent destroys muscle memory: you can no longer
  learn "that one is on the left", which is the whole benefit of a spatial UI.
- **Focus** is URGENT — who has been waiting longest, needs-input before error
  before done. It answers one keypress: "take me to whoever needs me".

So the same set of sessions is presented in a stable arrangement while the thing
that pulses within it is chosen by urgency.
"""

# Lower sorts first. Only these states are ever offered as a focus candidate;
# `working` and `idle` are not waiting on you, so they never steal focus.
URGENCY = {"needs-input": 0, "error": 1, "done": 2}
WAITING = frozenset(URGENCY)


def stable_order(sessions):
    """The arrangement. Deterministic, and independent of state."""
    return sorted(sessions, key=lambda s: str(s.get("key", "")))


def is_waiting(s):
    return s.get("state") in WAITING or bool(s.get("unread"))


def urgency_key(s):
    state = s.get("state")
    # An unread session in a non-waiting state still counts, just last.
    rank = URGENCY.get(state, len(URGENCY))
    # Oldest first: whoever has been waiting longest gets you first. Fair, and
    # it stops a chatty session from repeatedly jumping the queue.
    return (rank, float(s.get("state_since", 0.0)), str(s.get("key", "")))


def focus_candidate(sessions):
    """The one session `jump_to_glow` should go to, or None if nobody waits."""
    waiting = [s for s in sessions if is_waiting(s) and s.get("state") != "gone"]
    if not waiting:
        return None
    return min(waiting, key=urgency_key).get("key")


def cycle(sessions, current, delta):
    """Next/previous in STABLE order, wrapping. Returns a key, or None."""
    keys = [s.get("key") for s in stable_order(sessions) if s.get("state") != "gone"]
    if not keys:
        return None
    if current not in keys:
        return keys[0]
    return keys[(keys.index(current) + delta) % len(keys)]
