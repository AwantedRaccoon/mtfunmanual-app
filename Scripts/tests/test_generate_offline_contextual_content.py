import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "generate_offline_contextual_content.py"
)
SPEC = importlib.util.spec_from_file_location(
    "generate_offline_contextual_content",
    SCRIPT_PATH,
)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class FixedHTTPSURLTests(unittest.TestCase):
    def test_rejects_any_raw_port_delimiter(self) -> None:
        self.assertFalse(
            GENERATOR.fixed_https_url(
                "https://www.who.int:443/test"
            )
        )
        self.assertFalse(
            GENERATOR.fixed_https_url(
                "https://www.who.int:/test"
            )
        )

    def test_accepts_allowlisted_url_without_authority_decorations(
        self,
    ) -> None:
        self.assertTrue(
            GENERATOR.fixed_https_url(
                "https://www.who.int/test"
            )
        )

    def test_source_path_uses_frozen_repository_relative_grammar(
        self,
    ) -> None:
        self.assertTrue(
            GENERATOR.valid_source_path(
                "archive/quick/zh-CN/034-visit.md"
            )
        )
        for invalid in (
            "C:/foo",
            "~/foo",
            "/absolute/foo",
            "archive//foo",
            "archive/../foo",
            "archive/./foo",
            "archive/foo bar",
            "archive\\foo",
        ):
            with self.subTest(path=invalid):
                self.assertFalse(
                    GENERATOR.valid_source_path(invalid)
                )


class SourceAuthenticationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        lock_path = (
            Path(__file__).resolve().parents[2]
            / "docs/content/"
            / "offline-contextual-content-source-lock-v1.json"
        )
        cls.lock = json.loads(lock_path.read_text(encoding="utf-8"))
        cls.digest_by_path = {
            card["provenance"]["sourcePath"]:
                card["provenance"]["sourceFileSHA256"]
            for card in cls.lock["cards"]
        }

    def test_verify_lock_authenticates_every_provenance_path(self) -> None:
        with (
            mock.patch.object(GENERATOR, "run_git", return_value=b""),
            mock.patch.object(
                GENERATOR,
                "git_show",
                side_effect=lambda _repository, path: path.encode("utf-8"),
            ) as show,
            mock.patch.object(
                GENERATOR,
                "sha256",
                side_effect=lambda data:
                    self.digest_by_path[data.decode("utf-8")],
            ),
        ):
            GENERATOR.verify_lock(self.lock, Path("/candidate-source"))

        self.assertEqual(show.call_count, 48)
        self.assertEqual(
            {call.args[1] for call in show.call_args_list},
            set(self.digest_by_path),
        )

    def test_verify_lock_fails_closed_on_source_digest_mismatch(
        self,
    ) -> None:
        with (
            mock.patch.object(GENERATOR, "run_git", return_value=b""),
            mock.patch.object(GENERATOR, "git_show", return_value=b"wrong"),
        ):
            with self.assertRaisesRegex(
                ValueError,
                "source digest mismatch",
            ):
                GENERATOR.verify_lock(
                    self.lock,
                    Path("/candidate-source"),
                )

    def test_candidate_pack_removes_unreferenced_regional_claims_and_markdown(
        self,
    ) -> None:
        pack = GENERATOR.build_pack(self.lock)
        summaries = {
            card["id"]: card["summary"]
            for card in pack["cards"]
        }
        cards_by_id = {
            card["id"]: card
            for card in pack["cards"]
        }
        locked_by_id = {
            card["id"]: card
            for card in self.lock["cards"]
        }

        for card_id, summary in summaries.items():
            with self.subTest(card_id=card_id):
                self.assertFalse(
                    any(
                        line.lstrip().startswith(">")
                        for line in summary.splitlines()
                    )
                )
                note = cards_by_id[card_id]["provenance"][
                    "modificationNote"
                ]
                locked_summary = locked_by_id[card_id]["summary"]
                had_markdown_quote = any(
                    line.lstrip().startswith(">")
                    for line in locked_summary.splitlines()
                )
                self.assertEqual(
                    "把 Markdown 引用标记转换为纯文本" in note,
                    had_markdown_quote,
                )
                self.assertEqual(
                    "移除未被当前 sourceIDs 支持的地区性断言"
                    in note,
                    card_id in GENERATOR.UNREFERENCED_REGIONAL_CLAIMS,
                )

        for card_id in (
            "card.hiv-testing-prep-021",
            "card.prep-hrt-022",
            "card.hpv-vaccine-024",
            "card.surgery-options-026",
            "card.finding-affirming-therapist-033",
        ):
            with self.subTest(card_id=card_id):
                summary = summaries[card_id]
                self.assertNotIn("国内", summary)
                self.assertNotIn("大陆", summary)
                self.assertNotIn("医保", summary)
                self.assertNotIn("疾控", summary)
                self.assertNotIn("精神科医生", summary)
                self.assertNotIn(
                    "。；",
                    cards_by_id[card_id]["provenance"][
                        "modificationNote"
                    ],
                )

    def test_candidate_adaptation_rejects_duplicate_frozen_claim(
        self,
    ) -> None:
        card_id = "card.hiv-testing-prep-021"
        claim = GENERATOR.UNREFERENCED_REGIONAL_CLAIMS[card_id][0]

        with self.assertRaisesRegex(
            ValueError,
            "expected regional claim count is 2",
        ):
            GENERATOR.adapt_candidate_summary(
                card_id,
                f"{claim}\n{claim}",
            )

    def test_source_lock_parser_rejects_duplicate_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source-lock.json"
            path.write_text(
                '{"lockVersion":"1","lockVersion":"2"}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ValueError,
                "duplicate JSON key: lockVersion",
            ):
                GENERATOR.load_source_lock(path)

    def test_source_lock_rejects_unknown_nested_keys(self) -> None:
        mutations = (
            ("source", ("sources", 0), "unexpectedSourceField"),
            ("card", ("cards", 0), "unexpectedCardField"),
            (
                "provenance",
                ("cards", 0, "provenance"),
                "unexpectedProvenanceField",
            ),
        )
        for name, path, key in mutations:
            lock = copy.deepcopy(self.lock)
            target = lock
            for component in path:
                target = target[component]
            target[key] = "unexpected"
            with self.subTest(name=name):
                with self.assertRaisesRegex(
                    ValueError,
                    "unknown or missing",
                ):
                    GENERATOR.verify_lock(
                        lock,
                        Path("/candidate-source"),
                    )


if __name__ == "__main__":
    unittest.main()
