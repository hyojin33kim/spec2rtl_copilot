"""P0-P2 provenance and evidence-presentation contract tests."""

from __future__ import annotations

import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class TraceUiContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "manifests/catalog.json").read_text(encoding="utf-8"))
        cls.selection = json.loads((ROOT / "manifests/selection-context.json").read_text(encoding="utf-8"))
        cls.behavior_models = json.loads((ROOT / "manifests/behavior-models.json").read_text(encoding="utf-8"))
        cls.html = (ROOT / "app/ui/spec2rtl_harness_demo_v1_7_4.html").read_text(encoding="utf-8")

    def test_pdf_provenance_is_explicit(self):
        expected_pages = {
            "REQ-FC-E1": [74], "REQ-FC-E2": [74], "REQ-FC-F": [74], "REQ-FC-HJ": [75],
            "REQ-RC-ACCOUNT": [75], "REQ-FCT-INIT": [75], "REQ-FCT-ELIGIBLE": [75],
            "REQ-RC-ERR": [75], "REQ-LINK-INIT": [77], "REQ-LINK-ERROR": [81],
            "REQ-PKT-RECOVERY": [82],
            "REQ-ENC-SYMBOL": [64, 65], "REQ-ENC-DS-CORE": [67],
            "REQ-ENC-FIRST-NULL": [69], "REQ-ENC-NULL-DETECT": [69, 70],
            "REQ-ENC-PARITY-GATE": [70],
            "REQ-ENC-DISCONNECT": [70], "REQ-ENC-ESC": [70],
        }
        for requirement in self.catalog["requirements"]:
            spec = requirement["spec"]
            self.assertEqual(spec["pdf_pages"], expected_pages[requirement["id"]])
            self.assertEqual(spec["printed_pages"], spec["pdf_pages"])
            self.assertGreater(len(spec["excerpt"]), 40)
            self.assertTrue(spec["highlights"])
            for highlight in spec["highlights"]:
                self.assertGreaterEqual(highlight["x"], 0)
                self.assertLessEqual(highlight["x"] + highlight["width"], 100)
                self.assertGreaterEqual(highlight["y"], 0)
                self.assertLessEqual(highlight["y"] + highlight["height"], 100)

    def test_each_requirement_has_executable_contract(self):
        for requirement in self.catalog["requirements"]:
            self.assertEqual(requirement["trace_id"], requirement["id"])
            self.assertEqual(set(requirement["behavior"]), {"trigger", "precondition", "expected", "verdict"})
            self.assertTrue(requirement["result_ids"])
            self.assertTrue(requirement["waveform"]["signals"])
            self.assertLess(requirement["waveform"]["window_start"], requirement["waveform"]["window_end"])
            for layer in ("golden", "rtl", "test"):
                self.assertTrue(requirement["trace"][layer])
                for item in requirement["trace"][layer]:
                    self.assertTrue((ROOT / item["file"]).is_file())
                    self.assertLessEqual(item["start"], item["end"])

    def test_ui_exposes_required_views(self):
        for token in (
            "Spec PDF · page", "scrollSpecViewer", "specHighlight", "highlighted trace target", "Summary", "Golden", "Compile",
            "Simulation", "stdout.log", "VERDICT EVENT", "Open JUnit", "Download VCD",
        ):
            self.assertIn(token, self.html)

    def test_trace_explorer_and_verification_run_are_separated(self):
        for token in (
            "Trace Explorer", "Verification Run", "TRACE NAVIGATOR",
            "dockHead('SPEC'", "dockHead('BEHAVIOR'", "dockHead('GOLDEN'", "dockHead('RTL'", "dockHead('WAVE'",
            "selectionContext", "trace_id",
        ):
            self.assertIn(token, self.html)

    def test_trace_explorer_removes_redundant_status_copy(self):
        for removed in (
            "One selection context · Spec → Behavior → Golden → RTL → Wave",
            "Latest evidence:", "Open in Verification Run", "linked assets",
        ):
            self.assertNotIn(removed, self.html)

    def test_dock_move_arrows_are_removed_and_targeted_resizers_exist(self):
        for removed in (
            "dockSlotStyles", "dockNeighbors", "dockLayout", "moveDockPane",
            'title="Move left"', 'title="Move up"', 'title="Move down"', 'title="Move right"',
        ):
            self.assertNotIn(removed, self.html)
        for token in (
            "navWidthHandle", "startNavigatorResize", "navigatorResizeKey",
            "codeSplitter", "startCodeResize", "codeResizeKey",
        ):
            self.assertIn(token, self.html)

    def test_accessible_pdf_tabs_and_splitters_are_present(self):
        for token in (
            'aria-label="PDF controls"', 'aria-label="Zoom out"', 'aria-label="Zoom in"',
            'aria-label="Previous page"', 'aria-label="Next page"', "spec_total_pages",
            "sourceTabs", 'role="tablist"', 'role="tab"', "gridSplitter", 'role="separator"',
            "startGridResize", "gridResizeKey", ":focus-visible", "syntaxHighlightLine",
        ):
            self.assertIn(token, self.html)

    def test_layout_regressions_and_compact_header(self):
        for token in (
            "topbar.traceCompact{display:none}",
            ".topbar.traceCompact + #content .traceShell{height:calc(100vh - 16px);min-height:0}",
            "class=\"codeRow\"",
            ".codeRow .dockPane{position:relative", 'stroke-width="0.58"',
            'stroke-width="0.55"', 'aria-label="Highlighted trace target"',
            ".dockPane{margin:0}",
            ".dockPane.contextSelected{position:relative;z-index:4;border:1px solid #2d74bf}",
            ".codeSplitter{position:absolute", "transform:translateX(-50%)",
            "grid-template-columns:38fr 32fr 30fr", "gap:2px",
            "gridRatios.cols.join('fr ')", "gridRatios.rows.join('fr ')",
            "grid-template-columns:50fr 50fr;gap:2px", "codeSplit=50",
            "`${codeSplit}fr ${100-codeSplit}fr`",
            "t.id==='send_decrement'?12:0",
        ):
            self.assertIn(token, self.html)
        self.assertNotIn("<span>${esc(h.label)}</span>", self.html)

    def test_selection_event_contract_is_explicit(self):
        self.assertEqual(self.selection["event"], "trace:select")
        self.assertEqual(self.selection["example"]["trace_id"], "REQ-FC-E2")
        self.assertEqual(
            set(self.selection["consumers"]),
            {"spec", "behavior", "golden", "rtl", "wave", "properties"},
        )

    def test_compact_ide_navigation_and_real_wave_artifact(self):
        for token in (
            "hover-expand navigation rail", ".sidebar:hover", "docIcon",
            "Filter clause", "actual run artifact", "timescale", "waveform.vcd",
        ):
            self.assertIn(token, self.html)
        navigator = self.html.split("function traceNavigator(req){", 1)[1].split(
            "function changeSpecPage", 1
        )[0]
        for duplicated_layer in (
            "ECSS-E-ST-50-12C Rev.1", "Behavior (contract)", ">Golden<", ">RTL<", ">Test<", "${esc(r.id)}",
        ):
            self.assertNotIn(duplicated_layer, navigator)

    def test_navigator_follows_ecss_toc_and_defaults_to_542(self):
        self.assertIn("mvpSelected='REQ-ENC-SYMBOL'", self.html)
        self.assertIn("5.4 Encoding Layer", self.html)
        self.assertIn("5.5 Data Link Layer", self.html)
        self.assertIn("a.spec.clause.localeCompare(b.spec.clause", self.html)
        self.assertLess(self.html.index("5.4 Encoding Layer"), self.html.index("5.5 Data Link Layer"))

    def test_ask_ai_is_a_prominent_requirement_action(self):
        self.assertIn('class="btn qaButton"', self.html)
        self.assertIn('class="qaIcon" aria-hidden="true">✦</span>Ask AI', self.html)
        self.assertIn('aria-label="Ask AI about ${esc(req.id)}"', self.html)
        self.assertIn(".qaContext", self.html)
        self.assertNotIn("Ask about this trace", self.html)

    def test_behavior_model_is_an_explicit_counter_abstraction(self):
        model = self.behavior_models["models"][0]
        self.assertEqual(model["kind"], "behavioral_state_abstraction")
        self.assertIn("not an RTL control FSM", model["implementation_note"])
        self.assertEqual({state["id"] for state in model["states"]}, {"EMPTY", "AVAILABLE", "MAX"})
        transitions = {item["id"]: item for item in model["transitions"]}
        req = next(item for item in self.catalog["requirements"] if item["id"] == "REQ-FC-E2")
        self.assertEqual(
            set(req["behavior_model"]["transition_ids"]),
            {"send_decrement", "send_to_empty", "send_from_max"},
        )
        self.assertEqual(transitions["send_decrement"]["action"], "tx_credit -= 1")


if __name__ == "__main__":
    unittest.main()
