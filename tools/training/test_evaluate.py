import tempfile
import unittest
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError:  # The evaluator needs the ML environment; the dataset tests use only the standard library.
    np = None

from dataset import LABELS

ROCK, TREE, PLAYER = LABELS.index("rock"), LABELS.index("tree"), LABELS.index("player")
# A 3840 x 1736 viewport at 960: scale 0.25 with 263 px of padding above and below.
GEOMETRY = (0.25, 0.0, 263.0, 3840, 1736)


def raw_output(anchors):
    """Synthetic raw model output from (cx, cy, w, h, class, score) anchors in input pixels."""
    raw = np.zeros((4 + len(LABELS) + 32, len(anchors)), np.float32)
    for i, (cx, cy, w, h, label, score) in enumerate(anchors):
        raw[:4, i] = cx, cy, w, h
        raw[4 + label, i] = score
    return raw


@unittest.skipIf(np is None, "Run with the ML environment: .venv/bin/python")
class EvaluateTests(unittest.TestCase):
    def test_decode_matches_runtime_letterbox_and_class_aware_nms(self):
        from evaluate import decode
        raw = raw_output([(480, 480, 96, 43.4, ROCK, .9), (482, 480, 96, 43.4, ROCK, .8),
                          (480, 480, 96, 43.4, TREE, .7), (100, 300, 10, 10, PLAYER, .4),
                          (480, 100, 96, 40, PLAYER, .95)])
        labels, scores, boxes, anchors = decode(raw, .5, len(LABELS), *GEOMETRY)
        # The overlapping rock is suppressed, the tree is kept, the low score and padding-only box are dropped.
        self.assertEqual(labels.tolist(), [ROCK, TREE])
        self.assertEqual(anchors.tolist(), [0, 2])
        np.testing.assert_allclose(boxes[0], [.45, .45, .55, .55], atol=1e-5)

    def test_wide_input_letterbox_and_decode(self):
        from evaluate import decode, input_shape, letterbox
        self.assertEqual(input_shape({"inputSize": 960}), (960, 960))
        self.assertEqual(input_shape({"inputSize": 960, "inputHeight": 512}), (960, 512))
        # The same 3840 x 1736 viewport in a 960 x 512 input: scale 0.25 with 39 px of padding above and below.
        canvas, scale, pad_x, pad_y = letterbox(np.zeros((1736, 3840, 3), np.uint8), (960, 512))
        self.assertEqual((canvas.shape, scale, pad_x, pad_y), ((512, 960, 3), 0.25, 0.0, 39.0))
        self.assertTrue((canvas[:39] == 114).all() and (canvas[39:473] == 0).all() and (canvas[473:] == 114).all())
        _, _, boxes, _ = decode(raw_output([(480, 256, 96, 43.4, ROCK, .9)]), .5, len(LABELS), scale, pad_x, pad_y, 3840, 1736)
        np.testing.assert_allclose(boxes[0], [.45, .45, .55, .55], atol=1e-5)

    def test_split_scores_a_wide_input(self):
        from evaluate import evaluate_split
        with tempfile.TemporaryDirectory() as tmp:
            image, labels = Path(tmp) / "frame.jpg", Path(tmp) / "frame.txt"
            cv2.imwrite(str(image), np.zeros((1736, 3840, 3), np.uint8))
            labels.write_text(f"{ROCK} .45 .45 .55 .45 .55 .55 .45 .55\n")
            raw, shapes = raw_output([(480, 256, 96, 43.4, ROCK, .9)]), []
            predict = lambda canvas: (shapes.append(canvas.shape), (raw, np.zeros((32, 128, 240), np.float32)))[1]
            rock = evaluate_split(predict, [("match-a", image, labels)], (960, 512), .5, .5)["perClass"]["rock"]
        self.assertEqual(shapes, [(512, 960, 3)])
        self.assertEqual((rock["tp"], rock["fp"], rock["fn"]), (1, 0, 0))
        self.assertGreater(rock["maskIoU"], .9)

    def test_matching_counts_duplicates_and_wrong_classes_as_false_positives(self):
        from evaluate import match
        reference, reference_boxes = np.array([ROCK, ROCK]), np.array([[0, 0, .1, .1], [.5, .5, .6, .6]])
        labels, scores = np.array([ROCK, ROCK, ROCK, TREE]), np.array([.9, .8, .7, .6])
        boxes = np.array([[0, 0, .1, .1], [0, 0, .1, .1], [.5, .5, .6, .6], [.5, .5, .6, .6]])
        self.assertEqual(match(labels, scores, boxes, reference, reference_boxes).tolist(), [0, -1, 1, -1])

    def test_average_precision(self):
        from evaluate import average_precision
        self.assertAlmostEqual(average_precision([.9, .8, .7], [True, False, True], 2), (51 + 50 * 2 / 3) / 101)
        self.assertEqual(average_precision([], [], 3), 0.0)
        self.assertIsNone(average_precision([.9], [False], 0))

    def test_split_scores_classes_matches_and_confusions(self):
        from evaluate import evaluate_split
        with tempfile.TemporaryDirectory() as tmp:
            image, labels = Path(tmp) / "frame.jpg", Path(tmp) / "frame.txt"
            cv2.imwrite(str(image), np.zeros((1736, 3840, 3), np.uint8))
            labels.write_text(f"{ROCK} .45 .45 .55 .45 .55 .55 .45 .55\n{PLAYER} .1 .1 .2 .1 .2 .2 .1 .2\n")
            raw = raw_output([(480, 480, 96, 43.4, ROCK, .9), (144, 328.1, 96, 43.4, TREE, .8)])
            predict = lambda canvas: (raw, np.zeros((32, 240, 240), np.float32))
            result = evaluate_split(predict, [("match-a", image, labels)], 960, .5, .5)
        rock, player, tree = (result["perClass"][label] for label in ("rock", "player", "tree"))
        self.assertEqual((rock["tp"], rock["fp"], rock["fn"], rock["precision"], rock["recall"]), (1, 0, 0, 1, 1))
        self.assertGreater(rock["maskIoU"], .9)
        self.assertEqual((player["recall"], player["missedAs"]), (0, {"tree": 1}))
        self.assertEqual((tree["precision"], tree["recall"], tree["falsePositiveAs"]), (0, None, {"player": 1}))
        self.assertEqual(result["perClass"]["door"]["instances"], 0)
        self.assertEqual(set(result["perMatch"]["match-a"]), {"rock", "player", "tree"})

    def test_threshold_calibration_favors_precision_for_players(self):
        from evaluate import calibrate_thresholds
        with tempfile.TemporaryDirectory() as tmp:
            image, labels = Path(tmp) / "frame.jpg", Path(tmp) / "frame.txt"
            cv2.imwrite(str(image), np.zeros((1736, 3840, 3), np.uint8))
            labels.write_text(f"{PLAYER} .45 .45 .55 .45 .55 .55 .45 .55\n{ROCK} .1 .1 .2 .1 .2 .2 .1 .2\n")
            # One true player at 0.9, a false player at 0.6; the rock is found at 0.4 next to a false one at 0.35.
            raw = raw_output([(480, 480, 96, 43.4, PLAYER, .9), (800, 700, 40, 40, PLAYER, .6),
                              (144, 328.1, 96, 43.4, ROCK, .4), (900, 400, 30, 30, ROCK, .35)])
            predict = lambda canvas: (raw, np.zeros((32, 240, 240), np.float32))
            thresholds, table = calibrate_thresholds(predict, [("match-a", image, labels)], 960)
        self.assertEqual(thresholds["player"], .8)  # Above the false player, capped so tiny samples cannot mute players.
        self.assertEqual(thresholds["rock"], .4)
        self.assertNotIn("tree", thresholds)  # No reference instances: the manifest default applies.
        self.assertEqual(table["player"]["instances"], 1)


if __name__ == "__main__":
    unittest.main()
