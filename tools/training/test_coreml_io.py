import tempfile
import unittest
from pathlib import Path

try:
    import coremltools as ct
    import numpy as np
except ImportError:  # The rewrite needs the ML environment; the dataset tests use only the standard library.
    ct = None


def ultralytics_like_export(path):
    """A small program shaped like the Ultralytics export: an RGB image scaled by 1/255, float16 compute, a 3-D and a
    4-D output each cast back to float32, on the iOS 15 opset."""
    from coremltools.converters.mil import Builder as mb
    rng = np.random.RandomState(0)
    first, head = rng.randn(8, 3, 3, 3).astype(np.float32), rng.randn(4, 8, 1, 1).astype(np.float32)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 32, 48))], opset_version=ct.target.iOS15)
    def program(image):
        features = mb.silu(x=mb.conv(x=image, weight=first, pad_type="same"))
        boxes = mb.reshape(x=mb.conv(x=features, weight=head), shape=[1, 4, 32 * 48])
        return boxes, features
    model = ct.convert(program, inputs=[ct.ImageType(name="image", shape=(1, 3, 32, 48), scale=1 / 255)],
                       compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS15,
                       convert_to="mlprogram")
    model.save(str(path))


@unittest.skipIf(ct is None, "Run with the ML environment: .venv/bin/python")
class CoreMLIOTests(unittest.TestCase):
    def test_rewrite_removes_only_the_cpu_casts_and_keeps_the_numbers(self):
        from coreml_io import rewrite
        from PIL import Image
        with tempfile.TemporaryDirectory() as tmp:
            source, destination = Path(tmp) / "source.mlpackage", Path(tmp) / "rewritten.mlpackage"
            ultralytics_like_export(source)
            scale = rewrite(source, destination)
            self.assertEqual(scale, float(np.float32(1 / 255)))

            before = ct.models.MLModel(str(source), skip_model_load=True).get_spec()
            after = ct.models.MLModel(str(destination), skip_model_load=True).get_spec()
            (inp,) = after.description.input
            self.assertEqual(inp.type.WhichOneof("Type"), "multiArrayType")
            self.assertEqual(list(inp.type.multiArrayType.shape), [1, 3, 32, 48])
            self.assertTrue(all(o.type.multiArrayType.dataType == ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT16
                                for o in after.description.output))
            self.assertEqual([o.name for o in after.description.output], [o.name for o in before.description.output])

            def ops(spec):
                function = spec.mlProgram.functions["main"]
                return [op for op in function.block_specializations[function.opset].operations if op.type != "const"]
            removed = [op.type for op in ops(before)]
            for op in ops(after):
                removed.remove(op.type)
            self.assertEqual(sorted(removed), ["cast", "cast", "cast", "mul"])
            self.assertFalse([op for op in ops(after) if op.type in ("cast", "mul")])

            # On the CPU both run in float16 up to the reference's float32 input, so they agree to float16 precision;
            # on the Neural Engine the real export's outputs agree exactly (ZombsPerceive --compare-model).
            pixels = np.random.RandomState(1).randint(0, 256, (32, 48, 3), dtype=np.uint8)
            cpu = ct.ComputeUnit.CPU_ONLY
            old = ct.models.MLModel(str(source), compute_units=cpu).predict({"image": Image.fromarray(pixels)})
            planes = (pixels.astype(np.float32) * np.float32(scale)).astype(np.float16).transpose(2, 0, 1)[None]
            new = ct.models.MLModel(str(destination), compute_units=cpu).predict({"image": planes})
            for name in old:
                np.testing.assert_allclose(new[name].astype(np.float32), old[name], rtol=2e-2, atol=2e-2)

    def test_rewrite_refuses_to_overwrite(self):
        from coreml_io import rewrite
        with tempfile.TemporaryDirectory() as tmp:
            source, destination = Path(tmp) / "source.mlpackage", Path(tmp) / "rewritten.mlpackage"
            ultralytics_like_export(source)
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                rewrite(source, destination)


if __name__ == "__main__":
    unittest.main()
