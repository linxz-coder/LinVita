#define Ptr MacOSPtr
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#undef Ptr
#include <shader/spirv_recompiler.h>
#include <spirv_cross.hpp>
#include <spirv_msl.hpp>
#include <fstream>
#include <iostream>
#include <filesystem>
#include <set>
int main(int argc,char** argv) {
 if(argc!=4) {std::cerr<<"usage: shader-replay vertex.gxp fragment.gxp output-dir\n";return 2;}
 std::filesystem::create_directories(argv[3]);
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();
 id<MTLFunction> functions[2];
 for(int stage=0;stage<2;++stage){
  std::ifstream in(argv[stage+1],std::ios::binary);std::vector<uint8_t> raw((std::istreambuf_iterator<char>(in)),{});
  if(raw.size()<sizeof(SceGxmProgram))return 3;
  const auto &p=*reinterpret_cast<const SceGxmProgram*>(raw.data());
  FeatureState features{};features.support_shader_interlock=true;
  shader::Hints hints{};hints.color_format=SCE_GXM_COLOR_FORMAT_U8U8U8U8_ABGR;
  for(auto &f:hints.fragment_textures)f=SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR;
  auto code=shader::convert_gxp(p,stage?"captured-fragment":"captured-vertex",features,shader::Target::SpirVVulkan,hints).spirv;
  auto name=std::string(argv[3])+(stage?"/fragment":"/vertex");
  std::ofstream spv(name+".spv",std::ios::binary);spv.write((const char*)code.data(),code.size()*4);spv.close();
  spirv_cross::CompilerMSL compiler(code);auto resources=compiler.get_shader_resources();
  for(auto &v:resources.stage_inputs)std::cout<<(stage?"fragment":"vertex")<<" input "<<v.name<<" location="<<compiler.get_decoration(v.id,spv::DecorationLocation)<<" components="<<compiler.get_type(v.type_id).vecsize<<"\n";
  unsigned point=0;for(auto &v:resources.builtin_inputs)if(v.builtin==spv::BuiltInPointCoord){++point;std::cout<<"PointCoord components="<<compiler.get_type(v.value_type_id).vecsize<<"\n";}
  if(stage && point!=1) std::cerr<<"Expected exactly one PointCoord; continuing to verify pipeline rejection\n";
  const auto entry=compiler.get_entry_points_and_stages()[0];
  auto options=compiler.get_msl_options();options.set_msl_version(2,3);options.enable_point_size_builtin=true;compiler.set_msl_options(options);
  std::string msl=compiler.compile();std::ofstream(name+".metal")<<msl;
  NSError* error=nil;MTLCompileOptions* compileOptions=[MTLCompileOptions new];
  id<MTLLibrary> lib=[device newLibraryWithSource:[NSString stringWithUTF8String:msl.c_str()] options:compileOptions error:&error];
  if(!lib){std::cerr<<[[error description] UTF8String]<<"\n";return 5;}
  MTLFunctionConstantValues* constants=[MTLFunctionConstantValues new];bool srgb=false;
  if(stage)[constants setConstantValue:&srgb type:MTLDataTypeBool atIndex:0];
  functions[stage]=[lib newFunctionWithName:[NSString stringWithUTF8String:compiler.get_cleansed_entry_point_name(entry.name,entry.execution_model).c_str()] constantValues:constants error:&error];
  if(!functions[stage]){std::cerr<<[[error description] UTF8String]<<"\n";return 7;}
 }
 MTLRenderPipelineDescriptor* desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=functions[0];desc.fragmentFunction=functions[1];desc.inputPrimitiveTopology=MTLPrimitiveTopologyClassPoint;desc.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
 MTLVertexDescriptor* vd=[MTLVertexDescriptor vertexDescriptor];vd.attributes[0].format=MTLVertexFormatFloat4;vd.attributes[0].offset=0;vd.attributes[0].bufferIndex=30;vd.attributes[1].format=MTLVertexFormatFloat4;vd.attributes[1].offset=16;vd.attributes[1].bufferIndex=30;vd.layouts[30].stride=32;desc.vertexDescriptor=vd;
 desc.colorAttachments[0].writeMask=MTLColorWriteMaskNone;
 NSError* error=nil;id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:desc error:&error];
 if(!pipeline){std::cerr<<[[error description] UTF8String]<<"\n";return 6;}
 std::cout<<"PASS: captured point-sprite shaders compile and link into a Metal pipeline\n";
}
