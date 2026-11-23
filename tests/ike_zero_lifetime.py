"""Minimal IKEv1 PSK initiator reproducing iKuai's zero lifetime.
Runs only inside the disposable CI client network namespace.
"""
import hashlib
import hmac
import os
import socket
import struct
import subprocess
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

server, client, secret = sys.argv[1:]
parameters = subprocess.check_output([
    "openssl", "genpkey", "-genparam", "-algorithm", "DH",
    "-pkeyopt", "group:modp_3072",
])
prime = serialization.load_pem_parameters(parameters).parameter_numbers().p
private = int.from_bytes(os.urandom(48), "big")
public = pow(2, private, prime).to_bytes(384, "big")
cookie_i = os.urandom(8)
cookie_r = bytes(8)


def payload(next_type, body):
    return struct.pack("!BBH", next_type, 0, len(body) + 4) + body


def header(next_type, body, flags=0):
    return cookie_i + cookie_r + struct.pack("!BBBBII", next_type, 0x10, 2, flags, 0, 28 + len(body)) + body


def decode(packet):
    next_type = packet[16]
    offset = 28
    values = {}
    while next_type:
        following, _, length = struct.unpack("!BBH", packet[offset:offset + 4])
        if length < 4 or offset + length > len(packet):
            raise ValueError("Invalid IKE payload")
        values[next_type] = packet[offset + 4:offset + length]
        next_type = following
        offset += length
    return values


attributes = b"".join(struct.pack("!HH", 0x8000 | kind, value) for kind, value in (
    (1, 7), (14, 128), (2, 4), (3, 1), (4, 15), (11, 1), (12, 0),
))
transform = payload(0, bytes([1, 1, 0, 0]) + attributes)
proposal = payload(0, bytes([1, 1, 0, 1]) + transform)
sa = struct.pack("!II", 1, 1) + proposal
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
    connection.bind((client, 500))
    connection.settimeout(10)
    connection.sendto(header(1, payload(0, sa)), (server, 500))
    answer, _ = connection.recvfrom(65535)
    cookie_r = answer[8:16]
    assert cookie_r != bytes(8)
    nonce_i = os.urandom(32)
    connection.sendto(header(4, payload(10, public) + payload(0, nonce_i)), (server, 500))
    answer, _ = connection.recvfrom(65535)
    values = decode(answer)
    remote_public, nonce_r = values[4], values[10]
    shared = pow(int.from_bytes(remote_public, "big"), private, prime).to_bytes(384, "big")

    def prf(key, data):
        return hmac.new(key, data, hashlib.sha256).digest()

    skeyid = prf(secret.encode(), nonce_i + nonce_r)
    cookies = cookie_i + cookie_r
    skeyid_d = prf(skeyid, shared + cookies + b"\0")
    skeyid_a = prf(skeyid, skeyid_d + shared + cookies + b"\1")
    skeyid_e = prf(skeyid, skeyid_a + shared + cookies + b"\2")
    iv = hashlib.sha256(public + remote_public).digest()[:16]
    identity = bytes([1, 0, 0, 0]) + socket.inet_aton(client)
    hash_i = prf(skeyid, public + remote_public + cookies + sa + identity)
    cleartext = payload(8, identity) + payload(0, hash_i)
    cleartext += bytes((-len(cleartext)) % 16)
    encryptor = Cipher(algorithms.AES(skeyid_e[:16]), modes.CBC(iv)).encryptor()
    encrypted = encryptor.update(cleartext) + encryptor.finalize()
    connection.sendto(header(5, encrypted, flags=1), (server, 500))
    answer, _ = connection.recvfrom(65535)
    assert answer[19] & 1, "Expected encrypted authentication response"
    decryptor = Cipher(algorithms.AES(skeyid_e[:16]), modes.CBC(encrypted[-16:])).decryptor()
    decrypted = decryptor.update(answer[28:]) + decryptor.finalize()
    response = decode(answer[:28] + decrypted)
    expected = prf(skeyid, remote_public + public + cookie_r + cookie_i + sa + response[5])
    assert hmac.compare_digest(response[8], expected), "Responder authentication failed"
print("PASS authenticated IKEv1 with zero offered lifetime")
