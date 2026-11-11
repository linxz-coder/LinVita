# Shader replay on macOS

Build only the real GXP translator and its dependencies, without the emulator UI:

```sh
cmake -S tools/shader-regression -B build/shader-regression -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/shader-regression --target shader-tests shader-replay
build/shader-regression/shader/shader-tests
build/shader-regression/shader-replay vertex.gxp fragment.gxp output-directory
```

The replay harness matches the captured Uncharted point draw: two float4 vertex
attributes at offsets 0/16 with stride 32, point topology, RGBA8 color format,
interlock enabled, sRGB disabled, and no color writes. It translates the supplied
GXP pair to SPIR-V and MSL, compiles both through the host Metal driver, and links
the pipeline. A compilation failure is a nonzero exit. It saves generated shader
code for inspection. It does not simulate gameplay, execute the draw, or validate
device-specific behavior. Game shaders are supplied locally and are not included
in the repository.

For a before/after comparison, configure with
`-DSHADER_RECOMPILER_OVERRIDE=/absolute/path/to/previous/spirv_recompiler.cpp`,
build, and replay again. Reset that option to an empty value and rebuild before
running the final regression tests. This option affects only this standalone
host build, not the iOS application build.
