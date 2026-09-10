#!/usr/bin/env python3
"""Protocol tests for signed native authentication."""

from __future__ import annotations

import base64
import hashlib
import io
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest import mock


GUEST = Path(__file__).resolve().parents[1]
BROKER_PATH = (
    GUEST
    / "native-overlay/usr/local/lib/try-omarchy/native-authentication-broker"
)
broker = SourceFileLoader("native_authentication_broker", str(BROKER_PATH)).load_module()


class NativeAuthenticationProtocolTests(unittest.TestCase):
    request_id = "2a8adad0-e2e3-43a0-882f-82f64d691c86"
    challenge = "ab" * 32
    guest_id = "ef" * 32

    @classmethod
    def setUpClass(cls) -> None:
        cls.keys = tempfile.TemporaryDirectory(prefix="try-omarchy-auth-test-")
        private_key = Path(cls.keys.name) / "private.pem"
        generated = subprocess.run(
            [
                str(broker.OPENSSL),
                "ecparam",
                "-name",
                "prime256v1",
                "-genkey",
                "-noout",
                "-out",
                str(private_key),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        if generated.returncode:
            raise RuntimeError(generated.stderr.decode(errors="replace"))
        public_der = subprocess.run(
            [
                str(broker.OPENSSL),
                "pkey",
                "-in",
                str(private_key),
                "-pubout",
                "-outform",
                "DER",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        if not public_der.startswith(broker.P256_SPKI_PREFIX):
            raise RuntimeError("OpenSSL produced an unexpected P-256 public key")
        cls.private_key = private_key
        cls.public_key = public_der[len(broker.P256_SPKI_PREFIX) :]
        if len(cls.public_key) != 65:
            raise RuntimeError("OpenSSL produced an unexpected P-256 point")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.keys.cleanup()

    def request(self, operation: str = "sudo") -> dict[str, object]:
        if operation in {"disable", "enroll"}:
            user = requesting_user = tty = ""
        else:
            user = requesting_user = "test"
            tty = "/dev/pts/4"
        return {
            "challenge": self.challenge,
            "guestId": self.guest_id,
            "operation": operation,
            "requestId": self.request_id,
            "requestingUser": requesting_user,
            "service": "sudo",
            "tty": tty,
            "type": "authorize",
            "user": user,
            "version": 3,
        }

    def approved_response(
        self,
        request: dict[str, object],
        *,
        issued_at: int = 1_788_623_100,
    ) -> dict[str, object]:
        response = {
            **request,
            "type": "authorization-result",
            "approved": True,
            "issuedAt": issued_at,
            "expiresAt": issued_at + broker.APPROVAL_LIFETIME_SECONDS,
            "keyId": hashlib.sha256(self.public_key).hexdigest(),
            "publicKey": base64.b64encode(self.public_key).decode("ascii"),
            "signature": "",
        }
        signature = subprocess.run(
            [
                str(broker.OPENSSL),
                "dgst",
                "-sha256",
                "-sign",
                str(self.private_key),
            ],
            input=broker.authorization_payload(request, response),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        response["signature"] = base64.b64encode(signature).decode("ascii")
        return response

    def test_onepassword_approval_is_bound_to_action_and_identity(self):
        request = self.request()
        request.update(operation="onepassword-unlock", service="com.1password.1Password.unlock", tty="")
        broker.validate_request(request)
        response = self.approved_response(request)
        broker.verify_approval(request, response, pinned_public_key=self.public_key, now=response["issuedAt"])
        for field, value in [("service", "sudo"), ("requestingUser", "other"), ("tty", "/dev/pts/4")]:
            changed = {**request, field: value}
            with self.subTest(field=field), self.assertRaises(broker.AuthorizationError):
                broker.validate_request(changed)
        for field, value in [("user", "other"), ("challenge", "cd" * 32), ("requestId", "33333333-3333-4333-8333-333333333333")]:
            changed = {**request, field: value}
            # Re-labeling a signed response cannot authorize another request.
            forged = {**response, field: value}
            with self.subTest(field=field), self.assertRaises(broker.AuthorizationError):
                broker.verify_approval(changed, forged, pinned_public_key=self.public_key, now=response["issuedAt"])
        with self.assertRaises(broker.AuthorizationError):
            broker.verify_approval(request, response, pinned_public_key=self.public_key, now=response["expiresAt"] + 1)

    def test_request_encoding_matches_the_host_schema(self) -> None:
        request = self.request()
        encoded = broker.encode_request(request)
        self.assertEqual(
            encoded,
            json.dumps(request, separators=(",", ":"), sort_keys=True).encode("ascii")
            + b"\n",
        )

    def test_enrollment_rejects_sudo_context(self) -> None:
        request = self.request("enroll")
        broker.validate_request(request)
        request["user"] = "test"
        with self.assertRaises(broker.AuthorizationError):
            broker.validate_request(request)

    def test_disable_response_is_nonauthorizing_and_exact(self) -> None:
        request = self.request("disable")
        response = {
            **request,
            "type": "authorization-result",
            "approved": True,
            "issuedAt": 0,
            "expiresAt": 0,
            "keyId": "",
            "publicKey": "",
            "signature": "",
        }
        decoded = broker.decode_response(json.dumps(response).encode(), request)
        broker.verify_disable_response(decoded)

        authorization_material = dict(response)
        authorization_material["keyId"] = "ab" * 32
        with self.assertRaises(broker.AuthorizationError):
            broker.decode_response(json.dumps(authorization_material).encode(), request)

    def test_response_requires_the_original_request_identity(self) -> None:
        request = self.request()
        response = self.approved_response(request)
        decoded = broker.decode_response(json.dumps(response).encode(), request)
        self.assertTrue(decoded["approved"])
        for field, value in (
            ("requestId", "33333333-3333-4333-8333-333333333333"),
            ("challenge", "cd" * 32),
            ("guestId", "dc" * 32),
            ("tty", "/dev/pts/5"),
            ("user", "root"),
        ):
            changed = dict(response)
            changed[field] = value
            with self.assertRaises(broker.AuthorizationError):
                broker.decode_response(json.dumps(changed).encode(), request)

    def test_real_ecdsa_signature_and_time_window_are_verified(self) -> None:
        request = self.request()
        response = self.approved_response(request)
        decoded = broker.decode_response(json.dumps(response).encode(), request)
        self.assertEqual(
            broker.verify_approval(
                request,
                decoded,
                pinned_public_key=self.public_key,
                now=response["issuedAt"],
            ),
            self.public_key,
        )

        tampered = dict(decoded)
        signature = bytearray(base64.b64decode(tampered["signature"]))
        signature[-1] ^= 1
        tampered["signature"] = base64.b64encode(signature).decode("ascii")
        with self.assertRaises(broker.AuthorizationError):
            broker.verify_approval(
                request,
                tampered,
                pinned_public_key=self.public_key,
                now=response["issuedAt"],
            )
        with self.assertRaises(broker.AuthorizationError):
            broker.verify_approval(
                request,
                decoded,
                pinned_public_key=self.public_key,
                now=response["expiresAt"] + 1,
            )

    def test_enrollment_state_is_exact_atomic_and_mode_0600(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "native-authentication.json"
            broker.save_state(
                self.public_key,
                self.guest_id,
                path,
                enforce_root_owner=False,
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                broker.load_state(path, enforce_root_owner=False),
                (self.public_key, self.guest_id),
            )
            value = json.loads(path.read_text())
            self.assertEqual(set(value), broker.STATE_FIELDS)
            broker.remove_state(path, enforce_root_owner=False)
            self.assertFalse(path.exists())
            broker.remove_state(path, enforce_root_owner=False)

    def test_version_two_enrollment_state_migrates_without_changing_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "native-authentication.json"
            broker.save_state(
                self.public_key,
                self.guest_id,
                path,
                enforce_root_owner=False,
            )
            legacy = json.loads(path.read_text(encoding="ascii"))
            legacy["version"] = 2
            path.write_text(json.dumps(legacy, sort_keys=True) + "\n", encoding="ascii")
            path.chmod(0o600)

            with self.assertRaises(broker.AuthorizationError):
                broker.load_state(path, enforce_root_owner=False)
            self.assertTrue(broker.migrate_state(path, enforce_root_owner=False))
            self.assertEqual(
                broker.load_state(path, enforce_root_owner=False),
                (self.public_key, self.guest_id),
            )
            self.assertEqual(json.loads(path.read_text(encoding="ascii"))["version"], 3)

    def test_state_migration_is_a_noop_when_not_enrolled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "native-authentication.json"
            self.assertFalse(broker.migrate_state(path, enforce_root_owner=False))

    def test_fragmented_signed_round_trip(self) -> None:
        request = self.request()
        response = self.approved_response(request)
        client, host = socket.socketpair()

        def respond() -> None:
            received = bytearray()
            while not received.endswith(b"\n"):
                received.extend(host.recv(7))
            self.assertEqual(json.loads(received), request)
            encoded = json.dumps(response, separators=(",", ":"), sort_keys=True).encode() + b"\n"
            for offset in range(0, len(encoded), 5):
                host.sendall(encoded[offset : offset + 5])

        worker = threading.Thread(target=respond)
        worker.start()
        try:
            decoded = broker.exchange_on_descriptor(client.fileno(), request, timeout=2)
            self.assertTrue(decoded["approved"])
        finally:
            worker.join(timeout=2)
            client.close()
            host.close()
        self.assertFalse(worker.is_alive())

    def test_late_response_does_not_poison_the_next_request(self) -> None:
        request = self.request()
        response = self.approved_response(request)
        stale = {**response, "requestId": "33333333-3333-4333-8333-333333333333"}
        client, host = socket.socketpair()
        try:
            host.sendall(json.dumps(stale).encode() + b"\n" + json.dumps(response).encode() + b"\n")
            decoded = broker.exchange_on_descriptor(client.fileno(), request, timeout=0.2)
            broker.verify_approval(request, decoded, pinned_public_key=self.public_key, now=response["issuedAt"])
        finally:
            client.close()
            host.close()

    def test_stale_responses_do_not_reset_the_request_deadline(self) -> None:
        request = self.request()
        stale = {**self.approved_response(request), "requestId": "33333333-3333-4333-8333-333333333333"}
        client, host = socket.socketpair()
        try:
            host.sendall(json.dumps(stale).encode() + b"\n")
            with self.assertRaises(TimeoutError):
                broker.exchange_on_descriptor(client.fileno(), request, timeout=0.01)
        finally:
            client.close()
            host.close()

    def test_named_virtio_port_accepts_only_the_kernel_device_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            dev = Path(directory) / "dev"
            named_ports = dev / "virtio-ports"
            named_ports.mkdir(parents=True)
            port = named_ports / "dev.tryomarchy.authentication"
            port.symlink_to("../vport1p3")
            self.assertEqual(
                broker.authentication_device_path(port, enforce_root_owner=False),
                dev / "vport1p3",
            )
            port.unlink()
            for target in ("../../etc/shadow", "../vport1p3/extra", "/dev/vport1p3"):
                port.symlink_to(target)
                with self.assertRaises(broker.AuthorizationError):
                    broker.authentication_device_path(port, enforce_root_owner=False)
                port.unlink()

    def test_pam_rejects_non_sudo_and_non_interactive_contexts(self) -> None:
        base = {
            "PAM_TYPE": "auth",
            "PAM_SERVICE": "sudo",
            "PAM_USER": "test",
            "PAM_RUSER": "test",
            "PAM_TTY": "/dev/pts/4",
        }
        with mock.patch.object(broker.os, "getuid", return_value=0), mock.patch.object(
            broker.os, "geteuid", return_value=0
        ):
            with mock.patch.dict(broker.os.environ, {**base, "PAM_SERVICE": "login"}, clear=True):
                self.assertFalse(broker.authenticate_pam())
            with mock.patch.dict(broker.os.environ, {**base, "PAM_TTY": ""}, clear=True):
                self.assertFalse(broker.authenticate_pam())

    def test_pam_explains_clock_rejection_and_keeps_success_quiet(self) -> None:
        request = self.request()
        response = self.approved_response(request)
        env = {
            "PAM_TYPE": "auth", "PAM_SERVICE": "sudo", "PAM_USER": "test",
            "PAM_RUSER": "test", "PAM_TTY": "/dev/pts/4",
        }
        with mock.patch.object(broker.os, "getuid", return_value=0), \
             mock.patch.object(broker.os, "geteuid", return_value=0), \
             mock.patch.dict(broker.os.environ, env, clear=True), \
             mock.patch.object(broker, "load_state", return_value=(self.public_key, self.guest_id)), \
             mock.patch.object(broker, "make_request", return_value=request), \
             mock.patch.object(broker, "exchange", return_value=response):
            for offset in (-16, 0, 16):
                with self.subTest(offset=offset), \
                     mock.patch.object(broker.time, "time", return_value=response["issuedAt"] + offset), \
                     redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(broker.authenticate_pam(), offset == 0)
                    if offset == 0:
                        self.assertEqual(output.getvalue(), "")
                    else:
                        self.assertIn("clocks are out of sync", output.getvalue())
                        self.assertIn("Falling back to your guest password", output.getvalue())
                        self.assertNotIn(response["signature"], output.getvalue())


if __name__ == "__main__":
    unittest.main()
