"""Give an exported Core ML package float16 input and outputs, with the same numbers.

The Ultralytics export (half=True) takes an RGB image input. Core ML turns it into a float32 tensor, and the program
scales it by 1/255 and casts it to float16; at the end it casts both raw outputs back to float32. Core ML runs those four
operations on the CPU, around a program that is float16 throughout on the Neural Engine. On an M1 they took about a
third of each prediction.

This rewrite removes them and nothing else. The input becomes the float16 tensor [1, 3, H, W] (RGB planes) that the cast
produced: the runtime computes it with a table, float16(float32(v) * scale) for each 8-bit channel value v. The outputs
become the float16 tensors the casts read. The Neural Engine program is untouched, so every output value is unchanged.

Usage: python coreml_io.py <source.mlpackage> <destination.mlpackage>
The manifest must then name the new package's tree hash (train.export does this).
"""
import argparse
from pathlib import Path

FLOAT16_SPEC_VERSION = 7  # iOS 16 / macOS 13: float16 multiarray inputs and outputs.
FLOAT16_OPSET = "CoreML6"


def rewrite(source: Path, destination: Path) -> float:
    """Write the float16-I/O package; returns the input scale the runtime must apply."""
    import coremltools as ct
    from coremltools.proto import FeatureTypes_pb2, MIL_pb2

    if destination.exists():
        raise FileExistsError(f"{destination} exists; existing model artifacts are preserved")
    model = ct.models.MLModel(str(source.resolve()), skip_model_load=True)
    spec = model.get_spec()
    if spec.WhichOneof("Type") != "mlProgram":
        raise ValueError("Only ML programs are supported")
    function = spec.mlProgram.functions["main"]
    block = function.block_specializations[function.opset]
    ops = block.operations
    produced = {o.name: op for op in ops for o in op.outputs}

    def argument(op, name):
        return op.inputs[name].arguments[0].name

    def const_value(name):
        return produced[name].attributes["val"].immediateValue.tensor

    # The prologue: image -> mul(scale) -> cast(fp16) -> the first layer.
    (image,) = spec.description.input
    if image.type.WhichOneof("Type") != "imageType" or image.type.imageType.colorSpace != FeatureTypes_pb2.ImageFeatureType.RGB:
        raise ValueError("Expected one RGB image input")
    width, height = image.type.imageType.width, image.type.imageType.height
    (scale_op,) = [op for op in ops if op.type == "mul" and argument(op, "x") == image.name]
    scale_name = argument(scale_op, "y")
    scale = list(const_value(scale_name).floats.values)
    if len(scale) != 1:
        raise ValueError("Expected a scalar input scale")
    (to_half,) = [op for op in ops if op.type == "cast" and argument(op, "x") == scale_op.outputs[0].name]
    if const_value(argument(to_half, "dtype")).strings.values != ["fp16"]:
        raise ValueError("Expected the scaled input to be cast to float16")
    if any(op.type == "add" and argument(op, "x") in (image.name, scale_op.outputs[0].name) for op in ops):
        raise ValueError("Input bias is not supported")
    half_input = to_half.outputs[0].name

    # The epilogue: each output is a cast of a float16 value to float32.
    casts = {}
    for name in block.outputs:
        op = produced[name]
        if op.type != "cast" or const_value(argument(op, "dtype")).strings.values != ["fp32"]:
            raise ValueError(f"Output {name} is not a float32 cast")
        casts[name] = op

    removed = {id(scale_op), id(to_half)} | {id(op) for op in casts.values()}
    removed_consts = {scale_name, argument(to_half, "dtype")} | {argument(op, "dtype") for op in casts.values()}
    renames = {half_input: image.name}
    for name, op in casts.items():
        renames[argument(op, "x")] = name
    kept = []
    for op in ops:
        if id(op) in removed or (op.type == "const" and op.outputs[0].name in removed_consts):
            continue
        for value in op.inputs.values():
            for arg in value.arguments:
                if arg.name in renames:
                    arg.name = renames[arg.name]
        for out in op.outputs:
            if out.name in renames:
                out.name = renames[out.name]
        kept.append(op)
    # Nothing else may read what was removed.
    names = {o.name for op in kept for o in op.outputs} | {image.name}
    for op in kept:
        for value in op.inputs.values():
            for arg in value.arguments:
                if arg.name and arg.name not in names:
                    raise ValueError(f"{op.type} still reads removed value {arg.name}")
    del block.operations[:]
    block.operations.extend(kept)

    (inp,) = function.inputs
    inp.type.tensorType.dataType = MIL_pb2.FLOAT16
    image.type.ClearField("imageType")
    image.type.multiArrayType.shape.extend([1, 3, height, width])
    image.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT16
    for output in spec.description.output:
        output.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT16

    # Float16 inputs and outputs need the iOS 16 opset, which keeps every operation used here as it is.
    if function.opset != FLOAT16_OPSET:
        function.block_specializations[FLOAT16_OPSET].CopyFrom(block)
        del function.block_specializations[function.opset]
        function.opset = FLOAT16_OPSET
    spec.specificationVersion = max(spec.specificationVersion, FLOAT16_SPEC_VERSION)
    spec.description.metadata.userDefined["zombs.inputScale"] = repr(scale[0])

    destination.parent.mkdir(parents=True, exist_ok=True)
    ct.models.MLModel(spec, weights_dir=model.weights_dir, skip_model_load=True).save(str(destination))
    return scale[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    scale = rewrite(args.source, args.destination)
    print(f"Wrote {args.destination}: float16 input [1, 3, H, W] scaled by {scale!r}, float16 outputs")


if __name__ == "__main__":
    main()
