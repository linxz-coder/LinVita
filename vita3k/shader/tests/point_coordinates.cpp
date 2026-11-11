// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

#include <shader/spirv_recompiler.h>
#include <gtest/gtest.h>
#include <spirv_cross.hpp>
#include <cstddef>

namespace {
struct PointFixture {
    SceGxmProgram program{};
    SceGxmProgramVertexVaryings varyings{};
    SceGxmProgramAttributeDescriptor descriptors[2]{};
    uint64_t instructions = 0;

    PointFixture(bool half, unsigned count, bool sprite) {
        program.magic = 0x00505847;
        program.major_version = 1;
        program.minor_version = 4;
        program.size = sizeof(*this);
        program.program_flags = SCE_GXM_PROGRAM_FLAG_FRAGMENT;
        program.primary_reg_count = 8;
        program.varyings_offset = offsetof(PointFixture, varyings) - offsetof(SceGxmProgram, varyings_offset);
        program.primary_program_offset = offsetof(PointFixture, instructions) - offsetof(SceGxmProgram, primary_program_offset);
        program.secondary_program_offset = offsetof(PointFixture, instructions) - offsetof(SceGxmProgram, secondary_program_offset);
        program.secondary_program_offset_end = offsetof(PointFixture, instructions) - offsetof(SceGxmProgram, secondary_program_offset_end);
        varyings.output_param_type = SCE_GXM_PARAMETER_TYPE_F32;
        varyings.output_comp_count = 4;
        varyings.varyings_count = count;
        varyings.vertex_outputs1 = offsetof(PointFixture, descriptors) - offsetof(PointFixture, varyings) - offsetof(SceGxmProgramVertexVaryings, vertex_outputs1);
        for (unsigned i = 0; i < count; ++i) {
            // Two-component iterator, no non-dependent texture query.
            descriptors[i].attribute_info = 0x0040000F | (sprite ? 0x40000000 : 0) | (half ? 0x20000000 : 0);
            descriptors[i].size = 0x10;
        }
    }

    shader::usse::SpirvCode compile() const {
        shader::Hints hints{};
        hints.color_format = SCE_GXM_COLOR_FORMAT_U8U8U8U8_ABGR;
        return shader::convert_gxp(program, "point-coordinate-test", FeatureState{}, shader::Target::SpirVVulkan, hints).spirv;
    }
};
}

TEST(point_coordinates, direct_iterators_use_one_float2_rasterizer_builtin) {
    for (const bool half : { false, true }) {
        for (const unsigned count : { 1u, 2u }) {
            spirv_cross::Compiler reflection(PointFixture(half, count, true).compile());
            const auto resources = reflection.get_shader_resources();
            EXPECT_TRUE(resources.stage_inputs.empty());
            unsigned points = 0;
            for (const auto &input : resources.builtin_inputs) {
                if (input.builtin != spv::BuiltInPointCoord)
                    continue;
                ++points;
                const auto &type = reflection.get_type(input.value_type_id);
                EXPECT_EQ(type.basetype, spirv_cross::SPIRType::Float);
                EXPECT_EQ(type.width, 32);
                EXPECT_EQ(type.vecsize, 2);
                EXPECT_FALSE(reflection.has_decoration(input.resource.id, spv::DecorationLocation));
            }
            EXPECT_EQ(points, 1);
        }
    }
}

TEST(point_coordinates, regular_texcoord_keeps_vertex_varying_location) {
    spirv_cross::Compiler reflection(PointFixture(false, 1, false).compile());
    const auto resources = reflection.get_shader_resources();
    ASSERT_EQ(resources.stage_inputs.size(), 1);
    EXPECT_EQ(reflection.get_decoration(resources.stage_inputs[0].id, spv::DecorationLocation), 4);
    for (const auto &input : resources.builtin_inputs)
        EXPECT_NE(input.builtin, spv::BuiltInPointCoord);
}
