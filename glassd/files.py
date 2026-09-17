"""The one file this daemon will ever hand out: the user's own backdrop .glb.

⛔ **The path comes from the user's own config, never from the request.** There
is no name, no suffix and no directory in the URL to traverse, because the URL
carries nothing at all — `/backdrop.glb` means "whatever `backdrop.custom.glb`
points at". Anything that makes the path request-derived puts this daemon, which
already streams every agent's terminal, one bug away from serving the filesystem.

The route sits behind the same token as everything else (see `authed` in
glassd.py); this module only decides *whether* there is a file and *which* one.
"""

import os

# A room, not a film. The client parses this on its main thread and the headset
# has to hold it in memory alongside the composition layers.
MAX_BYTES = 192 * 1024 * 1024


def backdrop_path(cfg):
    """(path, None) when a custom backdrop is configured and servable.

    (None, reason) otherwise — the reason is for the log and the 404 body, and
    is always about the host's config, never about the caller.
    """
    bd = (cfg or {}).get("backdrop") or {}
    if str(bd.get("mode", "")) != "custom":
        return None, "backdrop.mode is not 'custom'"
    raw = ((bd.get("custom") or {}).get("glb") or "")
    if not isinstance(raw, str) or not raw.strip():
        return None, "backdrop.custom.glb is unset"
    path = os.path.expanduser(raw.strip())
    if not path.lower().endswith(".glb"):
        return None, "backdrop.custom.glb is not a .glb"
    if not os.path.isfile(path):
        return None, "backdrop.custom.glb does not exist"
    try:
        size = os.path.getsize(path)
    except OSError as e:
        return None, "backdrop.custom.glb is unreadable: %s" % e
    if size > MAX_BYTES:
        return None, "backdrop.custom.glb is %.0f MB — the limit is %.0f MB" % (
            size / 1048576.0, MAX_BYTES / 1048576.0)
    return path, None


def etag(path):
    """A cheap validator so a client does not re-download megabytes every launch.

    Size and mtime, not a hash: hashing 100 MB on every request costs more than
    the transfer it saves, and a backdrop that changes without either changing
    is a file the user replaced byte-for-byte in the same second.
    """
    st = os.stat(path)
    return '"%d-%d"' % (int(st.st_mtime), st.st_size)
