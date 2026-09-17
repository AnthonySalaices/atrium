"""Pairing: a short code on the host, typed once in the headset, exchanged for
the long-lived token. So the APK never carries a secret.

    host:    glasshouse pair          -> prints a 6-digit code, valid 10 minutes
    headset: first-run card           -> POST /pair {"code": "123456"}
    daemon:  code ok -> {"token": ..} -> client stores it in user://

Rules, all enforced here and unit-tested:

- one active code at a time; issuing a new one retires the old one
- single use: a code that worked is gone
- expiry (default 10 min)
- brute force is pointless: 5 wrong guesses retire the code and lock pairing
  for 5 minutes (10^6 codes / 5 guesses per 10 min)
- the daemon never logs the code or the token
"""

import secrets
import threading
import time

TTL_S = 600
MAX_TRIES = 5
LOCK_S = 300


class Pairing:
    def __init__(self, ttl=TTL_S, max_tries=MAX_TRIES, lock_s=LOCK_S, clock=time.time):
        self.ttl = ttl
        self.max_tries = max_tries
        self.lock_s = lock_s
        self.clock = clock
        self._lock = threading.Lock()
        self._code = None
        self._expires = 0.0
        self._tries = 0
        self._locked_until = 0.0

    def new_code(self):
        """Issue a fresh code. Clears any previous one and any lockout."""
        with self._lock:
            self._code = "%06d" % secrets.randbelow(1_000_000)
            self._expires = self.clock() + self.ttl
            self._tries = 0
            self._locked_until = 0.0
            return self._code, self.ttl

    def active(self):
        with self._lock:
            return self._code is not None and self.clock() < self._expires

    def seconds_left(self):
        with self._lock:
            if self._code is None:
                return 0
            return max(0, int(self._expires - self.clock()))

    def redeem(self, code):
        """Returns (ok, reason). reason in: ok, locked, none, expired, wrong."""
        with self._lock:
            now = self.clock()
            if now < self._locked_until:
                return False, "locked"
            if self._code is None:
                return False, "none"
            if now >= self._expires:
                self._code = None
                return False, "expired"
            if not isinstance(code, str) or not secrets.compare_digest(code.strip(), self._code):
                self._tries += 1
                if self._tries >= self.max_tries:
                    self._code = None
                    self._locked_until = now + self.lock_s
                    return False, "locked"
                return False, "wrong"
            self._code = None                      # single use
            return True, "ok"
