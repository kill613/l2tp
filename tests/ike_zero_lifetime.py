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

server, client, secret = sys.argv[1:4]
offer_lifetime = int(sys.argv[4]) if len(sys.argv) > 4 else 0
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
    (1, 7), (14, 128), (2, 4), (3, 1), (4, 15), (11, 1), (12, offer_lifetime),
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
    main_response_sa = decode(answer)[1]
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

    def accepted_lifetime(sa_body, duration_type):
        spi_length = sa_body[14]
        attributes = sa_body[24 + spi_length:]
        result = None
        while attributes:
            kind, field = struct.unpack("!HH", attributes[:4])
            if kind & 0x8000:
                value = field
                size = 4
            else:
                value = int.from_bytes(attributes[4:4 + field], "big")
                size = 4 + field
            if kind & 0x7fff == duration_type:
                result = value
            attributes = attributes[size:]
        assert result and result > 0, "Responder echoed a zero lifetime"
        if offer_lifetime:
            assert result == offer_lifetime, "Nonzero lifetime was changed"
        return result

    # Main Mode reply must advertise the corrected duration too.
    accepted_lifetime(main_response_sa, 12)
    # Proceed to Quick Mode with the same zero duration and verify HASH(2).
    quick_nonce_i = os.urandom(32)
    spi_i = os.urandom(4)
    quick_attributes = b"".join(struct.pack("!HH", 0x8000 | kind, value)
                               for kind, value in ((1, 1), (2, offer_lifetime),
                                                   (4, 2), (5, 5), (6, 128)))
    quick_transform = payload(0, bytes([1, 12, 0, 0]) + quick_attributes)
    quick_proposal = payload(0, bytes([1, 3, 4, 1]) + spi_i + quick_transform)
    quick_sa = struct.pack("!II", 1, 1) + quick_proposal
    identity_i = bytes([1, 17, 0, 0]) + socket.inet_aton(client)
    identity_r = bytes([1, 17]) + struct.pack("!H", 18563) + socket.inet_aton(server)
    quick_data = (payload(10, quick_sa) + payload(5, quick_nonce_i) +
                  payload(5, identity_i) + payload(0, identity_r))
    message_id = os.urandom(4)
    quick_hash_i = prf(skeyid_a, message_id + quick_data)
    quick_plain = payload(1, quick_hash_i) + quick_data
    quick_plain += bytes((-len(quick_plain)) % 16)
    quick_iv = hashlib.sha256(answer[-16:] + message_id).digest()[:16]

    def quick_packet(data, vector):
        encryptor = Cipher(algorithms.AES(skeyid_e[:16]), modes.CBC(vector)).encryptor()
        ciphertext = encryptor.update(data) + encryptor.finalize()
        prefix = cookie_i + cookie_r + bytes([8, 0x10, 32, 1]) + message_id
        return prefix + struct.pack("!I", len(ciphertext) + 28) + ciphertext

    request = quick_packet(quick_plain, quick_iv)
    connection.sendto(request, (server, 500))
    quick_answer, _ = connection.recvfrom(65535)
    assert quick_answer[20:24] == message_id, "Unexpected exchange"
    decryptor = Cipher(algorithms.AES(skeyid_e[:16]), modes.CBC(request[-16:])).decryptor()
    quick_clear = decryptor.update(quick_answer[28:]) + decryptor.finalize()
    parsed = decode(quick_answer[:28] + quick_clear)
    accepted_lifetime(parsed[1], 2)
    offset = struct.unpack("!H", quick_clear[2:4])[0]
    end = offset
    next_kind = quick_clear[0]
    while next_kind:
        next_kind, _, size = struct.unpack("!BBH", quick_clear[end:end + 4])
        assert size >= 4
        end += size
    expected = prf(skeyid_a, message_id + quick_nonce_i + quick_clear[offset:end])
    assert hmac.compare_digest(parsed[8], expected), "Quick Mode authentication failed"
    confirmation = prf(skeyid_a, b"\0" + message_id + quick_nonce_i + parsed[10])
    confirmation = payload(0, confirmation)
    confirmation += bytes((-len(confirmation)) % 16)
    connection.sendto(quick_packet(confirmation, quick_answer[-16:]), (server, 500))
print(f"PASS IKEv1 and Quick Mode, offered lifetime={offer_lifetime}")
