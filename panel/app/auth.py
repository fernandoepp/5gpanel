"""Contrasenyes amb scrypt (biblioteca estàndard) i límit d'intents de login."""
import base64
import hashlib
import hmac
import os
import time

N, R, P = 2 ** 15, 8, 1


def hash_password(pw):
    salt = os.urandom(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, n=N, r=R, p=P, maxmem=64 * 1024 * 1024)
    b = base64.b64encode
    return f'scrypt${N}${R}${P}${b(salt).decode()}${b(dk).decode()}'


def verify_password(pw, stored):
    try:
        alg, n, r, p, salt, dk = stored.split('$')
        if alg != 'scrypt':
            return False
        calc = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r),
                              p=int(p), maxmem=64 * 1024 * 1024)
        return hmac.compare_digest(calc, base64.b64decode(dk))
    except (ValueError, TypeError):
        return False


# Hash fals per gastar el mateix temps quan l'usuari no existeix
DUMMY = hash_password('x' * 16)


class RateLimiter:
    """Màxim `limit` errors per IP dins de `window` segons."""

    def __init__(self, limit=5, window=300):
        self.limit, self.window, self.fails = limit, window, {}

    def blocked(self, ip):
        now = time.time()
        f = [t for t in self.fails.get(ip, []) if now - t < self.window]
        self.fails[ip] = f
        return len(f) >= self.limit

    def fail(self, ip):
        self.fails.setdefault(ip, []).append(time.time())

    def reset(self, ip):
        self.fails.pop(ip, None)
