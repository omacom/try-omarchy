from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
agent = SourceFileLoader("onepassword_touch_id_agent", str(
    ROOT / "native-overlay/usr/local/lib/try-omarchy/onepassword-touch-id-agent")).load_module()


class OnePasswordAuthorizationTests(unittest.TestCase):
    def harness(self, *, alive=True, active=True, sender=True, canceled=False):
        service = agent.Agent.__new__(agent.Agent)
        service.user = SimpleNamespace(pw_uid=1000, pw_name="test")
        service.GLib = SimpleNamespace(Variant=lambda signature, value: value,
                                      idle_add=lambda callback, *args: callback(*args))
        service.call = mock.Mock()
        service.active = mock.Mock(return_value=active)
        service.authority_sender = mock.Mock(return_value=sender)
        service.run_child = mock.Mock(return_value=True)
        service.lock = threading.Lock()
        request = {"process": SimpleNamespace(alive=lambda: alive),
                   "sender": ":1.25", "cancel": threading.Event(),
                   "invocation": mock.Mock()}
        if canceled:
            request["cancel"].set()
        service.pending = {"cookie": request}
        return service, request

    def authenticate(self, service, request, action=agent.UNLOCK, uid=1000):
        service.authenticate("cookie", action, "Authenticate", [("unix-user", {"uid": uid})], request)

    def test_only_unlock_uses_touch_id_and_replies_with_the_requested_identity(self):
        service, request = self.harness()
        self.authenticate(service, request)
        self.assertEqual(service.run_child.call_count, 1)
        self.assertIn("onepassword-unlock", service.run_child.call_args.args[0])
        service.call.assert_called_once_with("AuthenticationAgentResponse2",
            (1000, "cookie", ("unix-user", {"uid": 1000})))
        request["invocation"].return_value.assert_called_once_with(None)

    def test_other_actions_and_other_users_never_receive_host_approval(self):
        for action, uid in [("com.1password.1Password.authorizeCLI", 1000),
                            ("com.1password.1Password.authorizeSshAgent", 1000),
                            ("org.freedesktop.policykit.exec", 1000), (agent.UNLOCK, 0)]:
            with self.subTest(action=action, uid=uid):
                service, request = self.harness()
                self.authenticate(service, request, action, uid)
                service.call.assert_not_called()
                self.assertTrue(service.run_child.call_args.kwargs["user"])
                self.assertTrue(service.run_child.call_args.args[0][0].endswith("onepassword-password-dialog"))

    def test_denied_touch_id_uses_pam_fallback_without_forging_a_response(self):
        service, request = self.harness()
        service.run_child.side_effect = [False, True]
        self.authenticate(service, request)
        self.assertEqual(service.run_child.call_count, 2)
        service.call.assert_not_called()

    def test_cancellation_cannot_be_overridden_by_late_approval(self):
        service, request = self.harness(canceled=True)
        self.authenticate(service, request)
        service.call.assert_not_called()
        request["invocation"].return_value.assert_not_called()
        request["invocation"].return_dbus_error.assert_called_once()

    def test_process_exit_session_change_and_authority_restart_invalidate_approval(self):
        for options in [{"alive": False}, {"active": False}, {"sender": False}]:
            with self.subTest(options=options):
                service, request = self.harness(**options)
                self.authenticate(service, request)
                service.call.assert_not_called()

    def test_unauthenticated_dbus_caller_is_rejected_before_processing_request(self):
        service, request = self.harness(sender=False)
        invocation = mock.Mock()
        parameters = mock.Mock()
        service.handle(None, ":1.99", "/fake", agent.AGENT_INTERFACE,
                       "BeginAuthentication", parameters, invocation)
        parameters.unpack.assert_not_called()
        service.run_child.assert_not_called()
        invocation.return_dbus_error.assert_called_once()

    def test_stat_parser_handles_parentheses_and_spaces_in_process_names(self):
        fields = ["S"] + ["0"] * 18 + ["123456"] + ["0"] * 4
        self.assertEqual(agent.process_start_time("42 (1Password (main)) " + " ".join(fields)), 123456)


if __name__ == "__main__":
    unittest.main()
