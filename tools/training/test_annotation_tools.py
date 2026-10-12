import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from annotate import load_for_review, prepare_review
from dataset import LABELS, load_sessions
from select_frames import allocate, coarse_to_fine, full_pass, informative, select, spread, taken_frames

HAS_CV = all(importlib.util.find_spec(name) for name in ("cv2", "numpy"))


def corpus(root: Path, matches: dict, assignments: dict, fps: float = 5.0) -> None:
    """Sessions in the recorder format: id → (mode, seconds); images are placeholders."""
    for match, (mode, seconds) in matches.items():
        folder = root / match
        (folder / "images").mkdir(parents=True)
        (folder / "session.json").write_text(json.dumps(dict(matchID=match, mode=mode)))
        rows = []
        for i in range(int(seconds * fps)):
            name = f"images/{i * 6:06d}.jpg"
            (folder / name).write_bytes(b"jpeg")
            rows.append(dict(image=name, matchID=match, mode=mode, timestamp=i / fps, width=64, height=48))
        (folder / "frames.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (root / "split-assignments.json").write_text(json.dumps(dict(assignments={m: dict(split=s, mode=matches[m][0])
                                                                              for m, s in assignments.items()})))


def rows(timestamps):
    return [dict(timestamp=t, image=f"images/{i:06d}.jpg") for i, t in enumerate(timestamps)]


class SelectFramesTests(unittest.TestCase):
    def test_allocation_respects_floor_total_and_availability(self):
        quota = allocate(10, dict(a=1, b=1, c=2), dict(a=100, b=2, c=100), floor=1)
        self.assertEqual(sum(quota.values()), 10)
        self.assertEqual(quota["b"], 2)
        self.assertGreater(quota["c"], quota["a"])
        self.assertEqual(allocate(10, dict(a=1), dict(a=3), floor=1), dict(a=3))

    def test_spread_is_even_and_gapped(self):
        picks = spread(rows([i / 5 for i in range(300)]), 6, 2.0)
        times = [p["timestamp"] for p in picks]
        self.assertEqual(len(picks), 6)
        self.assertTrue(all(b - a >= 2.0 for a, b in zip(times, times[1:])))
        self.assertTrue(all(abs(t - (i + 0.5) * 59.8 / 6) <= 0.1 + 1e-9 for i, t in enumerate(times)))  # Nearest frame to each slice centre.

    def test_informative_takes_the_best_frame_of_each_slice(self):
        pool = rows([i / 5 for i in range(300)])
        score = lambda r: -abs(r["timestamp"] % 20 - 7)  # Best at 7 s into every 20 s slice.
        picks = informative(pool, 3, 2.0, score)
        self.assertEqual([p["timestamp"] for p in picks], [7.0, 27.0, 47.0])

    def test_rounds_are_balanced_spread_and_clear_of_reviewed_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            matches = dict(trainSolo=("solo", 60), trainDuo=("duo", 60), valSquad=("squad", 60), testSolo=("solo", 60))
            corpus(root, matches, dict(trainSolo="train", trainDuo="train", valSquad="val", testSolo="test"))
            (root / "trainDuo" / "annotations").mkdir()
            (root / "trainDuo" / "annotations" / "000300.json").write_text(json.dumps(dict(reviewed=True, objects=[])))  # t = 10 s
            evidence = root / "evidence"
            evidence.mkdir()
            (evidence / "ADUOOO-000600-draft.json").write_text("{}")  # Not a known suffix: ignored.
            calls = []
            queue = select(root, 20, min_gap=2.0, min_per_match=2, score=lambda r: calls.append(r) or r["timestamp"], evidence=[evidence])
            frames = queue["frames"]
            self.assertEqual([sum(f["split"] == s for f in frames) for s in ("train", "val", "test")], [14, 3, 3])
            self.assertTrue(any(f["split"] != "train" for f in frames[:7]), "an interrupted round must not be all training frames")
            duo = [f["timeSeconds"] for f in frames if f["matchID"] == "trainDuo"]
            self.assertTrue(all(abs(t - 10.0) >= 2.0 for t in duo))
            self.assertGreater(len(duo), sum(f["matchID"] == "trainSolo" for f in frames), "team modes get more frames")
            for match in matches:
                times = sorted(f["timeSeconds"] for f in frames if f["matchID"] == match)
                self.assertTrue(all(b - a >= 2.0 for a, b in zip(times, times[1:])))
            self.assertEqual({f["reason"] for f in frames if f["split"] == "train"}, {"informative"})
            self.assertEqual({f["reason"] for f in frames if f["split"] != "train"}, {"evenly spaced"})
            self.assertTrue(all("train" in str(r["image_path"]) for r in calls), "the model never ranks held-out frames")

    def test_coarse_to_fine_covers_everything_and_spreads_early(self):
        pool = rows(range(100))
        order = [r["timestamp"] for r in coarse_to_fine(pool)]
        self.assertEqual(sorted(order), list(range(100)))
        self.assertEqual(order[:4], [0, 50, 25, 75])
        self.assertGreater(max(order[:16]) - min(order[:16]), 90)

    def test_full_pass_takes_every_spaced_frame_after_carried_over_ones(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            corpus(root, dict(a=("duo", 20), b=("solo", 20), c=("solo", 20)), dict(a="train", b="val", c="test"))
            (root / "a" / "annotations").mkdir()
            (root / "a" / "annotations" / "000060.json").write_text(json.dumps(dict(reviewed=True, objects=[])))  # t = 2 s
            queue = full_pass(root, min_gap=2.0, first=[dict(matchID="b", image="images/000300.jpg")])  # t = 10 s
            frames = queue["frames"]
            self.assertEqual((frames[0]["matchID"], frames[0]["image"]), ("b", "images/000300.jpg"))
            keys = [(f["matchID"], f["image"]) for f in frames]
            self.assertEqual(len(keys), len(set(keys)))
            for match in "abc":
                times = sorted(f["timeSeconds"] for f in frames if f["matchID"] == match)
                self.assertTrue(all(y - x >= 2.0 for x, y in zip(times, times[1:])))
                self.assertGreaterEqual(len(times), 8)
            self.assertTrue(all(abs(f["timeSeconds"] - 2.0) >= 2.0 for f in frames if f["matchID"] == "a"))
            self.assertEqual({f["split"] for f in frames[1:7]}, {"train", "val", "test"}, "splits interleave from the start")

    def test_reviewer_drafts_count_as_taken(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            corpus(root, {"2026-10-04T18-35-51Z-4DBB48": ("solo", 10)}, {"2026-10-04T18-35-51Z-4DBB48": "val"})
            (root / "evidence" / "worker").mkdir(parents=True)
            (root / "evidence" / "worker" / "4DBB48-000030-draft.json").write_text("{}")
            taken = taken_frames(load_sessions(root), [root / "evidence"])
            self.assertEqual(taken["2026-10-04T18-35-51Z-4DBB48"], [1.0])


class AnnotateDraftTests(unittest.TestCase):
    def frame(self, root: Path) -> dict:
        (root / "match" / "images").mkdir(parents=True)
        image = root / "match" / "images" / "000006.jpg"
        image.write_bytes(b"jpeg bytes")
        return dict(image_path=image, annotation_path=root / "match" / "annotations" / "000006.json")

    def test_saved_annotation_wins_over_a_marked_draft(self):
        with tempfile.TemporaryDirectory() as tmp:
            frame = self.frame(Path(tmp))
            self.assertEqual(load_for_review(frame)["objects"], [])
            drafts = Path(tmp) / "match" / "model-drafts"
            drafts.mkdir()
            draft = dict(label="tree", polygon=[[0, 0], [1, 0], [1, 1]], confidence=0.9, source="sam")
            (drafts / "000006.json").write_text(json.dumps(dict(reviewed=False, objects=[draft], draft=dict(model="m"))))
            loaded = load_for_review(frame)
            self.assertEqual((loaded["objects"], loaded["draft"], loaded["reviewed"]), ([draft], dict(model="m"), False))
            frame["annotation_path"].parent.mkdir()
            frame["annotation_path"].write_text(json.dumps(dict(objects=[])))
            self.assertNotIn("draft", load_for_review(frame))

    def test_saving_a_draft_keeps_only_label_and_polygon(self):
        with tempfile.TemporaryDirectory() as tmp:
            frame = self.frame(Path(tmp))
            saved = prepare_review(dict(reviewed=True, objects=[dict(label="rock", polygon=[[0, 0], [0.5, 0], [0.5, 0.5]],
                                                                     confidence=0.42, source="detector")],
                                        review=dict(reviewer="tester", notes="checked", sceneObjectsReviewed=True, negative=False)),
                                   frame["image_path"])
            self.assertEqual(saved["objects"], [dict(label="rock", polygon=[[0, 0], [0.5, 0], [0.5, 0.5]])])
            self.assertEqual(len(saved["review"]["imageSHA256"]), 64)


@unittest.skipUnless(HAS_CV, "needs OpenCV and NumPy (.venv)")
class AnnotationQATests(unittest.TestCase):
    square = staticmethod(lambda x, y, s=0.1: [[x, y], [x + s, y], [x + s, y + s], [x, y + s]])

    def test_duplicates_conflicts_and_self_count_are_errors(self):
        from annotation_qa import check
        objects = [dict(label="player", polygon=self.square(0.1, 0.1)), dict(label="rock", polygon=self.square(0.1, 0.1)),
                   dict(label="tree", polygon=self.square(0.5, 0.5)), dict(label="tree", polygon=self.square(0.5, 0.5)),
                   dict(label="self_player", polygon=self.square(0.3, 0.3)), dict(label="self_player", polygon=self.square(0.7, 0.2))]
        result = check(dict(objects=objects), "solo")
        self.assertEqual(len(result["errors"]), 3)
        self.assertIn("one object with two classes", result["errors"][0])
        self.assertIn("the same object twice", result["errors"][1])
        self.assertIn("2 self_player", result["errors"][2])

    def test_warnings_for_misses_missing_self_and_team_markers(self):
        from annotation_qa import check
        objects = [dict(label="player", polygon=self.square(0.1, 0.1)), dict(label="tree", polygon=self.square(0.5, 0.5))]
        detections = [dict(label="ground_item", polygon=self.square(0.8, 0.8, 0.05), confidence=0.9),   # nothing covers it
                      dict(label="tree", polygon=self.square(0.5, 0.5), confidence=0.95),             # covered
                      dict(label="rock", polygon=self.square(0.3, 0.7, 0.05), confidence=0.4)]       # not confident
        result = check(dict(objects=objects), "duo", detections)
        self.assertEqual(result["errors"], [])
        warnings = " | ".join(result["warnings"])
        self.assertIn("no self_player", warnings)
        self.assertIn("no ally_marker", warnings)
        self.assertIn("possible miss: model sees a ground_item (0.90)", warnings)
        self.assertNotIn("rock", warnings)
        self.assertNotIn("ally_marker", " ".join(check(dict(objects=objects), "solo")["warnings"]))


@unittest.skipUnless(HAS_CV, "needs OpenCV and NumPy (.venv)")
class PrelabelTests(unittest.TestCase):
    def test_split_object_becomes_one_bridged_polygon_without_specks(self):
        import cv2
        import numpy as np
        from outline import mask_to_polygon
        mask = np.zeros((100, 200), np.uint8)
        mask[10:60, 10:60] = 1
        mask[20:50, 120:180] = 1   # Second visible piece of the same object.
        mask[90, 195] = 1          # Speck.
        polygon = mask_to_polygon(mask)
        filled = np.zeros_like(mask)
        cv2.fillPoly(filled, [np.round(np.array(polygon)).astype(np.int32)], 1)
        self.assertGreater((filled & mask).sum() / mask[:89].sum(), 0.9)
        self.assertEqual(filled[90, 195], 0)
        self.assertIsNone(mask_to_polygon(np.zeros((10, 10), np.uint8)))

    def test_drafts_use_sam_except_for_walls(self):
        import numpy as np
        from prelabel import draft_objects
        classes = len(LABELS)
        raw = np.full((4 + classes + 32, 2), -1.0, np.float32)
        proto = np.full((32, 240, 240), -1.0, np.float32)
        # A 960 × 434 frame sits unscaled in the 960 input with 263 px of padding above.
        for anchor, (label, (x0, y0)) in enumerate([("tree", (100, 100)), ("wall", (500, 200))]):
            raw[:4, anchor] = [x0 + 50, y0 + 263 + 50, 100, 100]
            raw[4:4 + classes, anchor] = 0.0
            raw[4 + LABELS.index(label), anchor] = 0.9
            raw[4 + classes:, anchor] = 0.0
            raw[4 + classes + anchor, anchor] = 10.0
            proto[anchor, (y0 + 263) // 4:(y0 + 263 + 100) // 4, x0 // 4:(x0 + 100) // 4] = 1.0

        class Outliner:
            def set_image(self, image):
                self.image = image

            def outline(self, boxes):
                return [[[b[0] + 5, b[1] + 5], [b[2] - 5, b[1] + 5], [b[2] - 5, b[3] - 5], [b[0] + 5, b[3] - 5]] for b in boxes]

        objects = draft_objects(np.zeros((434, 960, 3), np.uint8), lambda canvas: (raw, proto), Outliner(), 960, 0.3)
        by_label = {o["label"]: o for o in objects}
        self.assertEqual((by_label["tree"]["source"], by_label["wall"]["source"]), ("sam", "detector"))
        xs, ys = zip(*by_label["tree"]["polygon"])
        self.assertAlmostEqual(min(xs) * 960, 100, delta=8)
        self.assertAlmostEqual(max(ys) * 434, 200, delta=8)
        self.assertEqual(by_label["tree"]["confidence"], 0.9)

    def test_drafts_from_a_wide_input(self):
        import numpy as np
        from prelabel import draft_objects
        classes = len(LABELS)
        raw = np.full((4 + classes + 32, 1), -1.0, np.float32)
        proto = np.full((32, 128, 240), -1.0, np.float32)
        # The 960 × 434 frame sits unscaled in a 960 × 512 input with 39 px of padding above.
        raw[:4, 0] = [550, 39 + 250, 100, 100]
        raw[4:4 + classes, 0] = 0.0
        raw[4 + LABELS.index("wall"), 0] = 0.9
        raw[4 + classes:, 0] = 0.0
        raw[4 + classes, 0] = 10.0
        proto[0, (39 + 200) // 4:(39 + 300) // 4, 500 // 4:600 // 4] = 1.0
        objects = draft_objects(np.zeros((434, 960, 3), np.uint8), lambda canvas: (raw, proto), None, (960, 512), 0.3)
        xs, ys = zip(*objects[0]["polygon"])
        self.assertEqual((objects[0]["label"], objects[0]["source"]), ("wall", "detector"))
        self.assertAlmostEqual(min(xs) * 960, 500, delta=8)
        self.assertAlmostEqual(min(ys) * 434, 200, delta=8)

    def test_held_out_annotated_and_drafted_frames_are_not_drafted(self):
        from prelabel import frames_to_draft
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            corpus(root, dict(train=("duo", 2), test=("solo", 2)), dict(train="train", test="test"))
            (root / "train" / "annotations").mkdir()
            (root / "train" / "annotations" / "000000.json").write_text("{}")
            (root / "train" / "model-drafts").mkdir()
            (root / "train" / "model-drafts" / "000006.json").write_text("{}")
            queue = [dict(matchID="train", image=f"images/{i:06d}.jpg") for i in (0, 6, 12)]
            queue += [dict(matchID="test", image="images/000000.jpg"), dict(matchID="gone", image="images/000000.jpg")]
            todo, skipped = frames_to_draft(load_sessions(root), queue, dict(train="train", test="test"))
            self.assertEqual([row["image"] for row, _ in todo], ["images/000012.jpg"])
            self.assertEqual(todo[0][1], root / "train" / "model-drafts" / "000012.json")
            self.assertEqual(skipped, {"test split": 1, "annotated": 1, "drafted": 1, "unknown": 1})


if __name__ == "__main__":
    unittest.main()
