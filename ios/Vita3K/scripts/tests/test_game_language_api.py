#!/usr/bin/env python3
"""Exercise the real guest API body with a minimal host-side environment.
Regression: the game's effective language must override a different global one.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[4]
source=(root/'vita3k/modules/SceAppUtil/SceAppUtil.cpp').read_text()
start=source.index('EXPORT(SceInt32, sceAppUtilSystemParamGetInt,')
end=source.index('\nEXPORT(',start+1)
body=source[start:end]
preamble=r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <util/system.h>
using SceInt32 = int32_t;
enum SceSystemParamId { SCE_SYSTEM_PARAM_ID_LANG, SCE_SYSTEM_PARAM_ID_ENTER_BUTTON,
 SCE_SYSTEM_PARAM_ID_DATE_FORMAT, SCE_SYSTEM_PARAM_ID_TIME_FORMAT,
 SCE_SYSTEM_PARAM_ID_TIME_ZONE, SCE_SYSTEM_PARAM_ID_SUMMERTIME };
constexpr int SCE_APPUTIL_ERROR_PARAMETER = -1;
struct Current { int sys_lang = SCE_SYSTEM_PARAM_LANG_ENGLISH_US; };
struct Config { int sys_lang = SCE_SYSTEM_PARAM_LANG_ENGLISH_US;
 int sys_button=1,sys_date_format=0,sys_time_format=0; Current current_config; };
struct Env { Config cfg; } emuenv;
#define EXPORT(result,name,...) result name(__VA_ARGS__)
#define TRACY_FUNC(...)
#define STUBBED(...)
#define RET_ERROR(code) (code)
'''
test=r'''
int main() {
 int value=-99;
 // Global English, Chinese override for Golden Abyss.
 emuenv.cfg.current_config.sys_lang=SCE_SYSTEM_PARAM_LANG_CHINESE_T;
 assert(sceAppUtilSystemParamGetInt(SCE_SYSTEM_PARAM_ID_LANG,&value)==0);
 assert(value==SCE_SYSTEM_PARAM_LANG_CHINESE_T);
 assert(emuenv.cfg.sys_lang==SCE_SYSTEM_PARAM_LANG_ENGLISH_US);
 // Switching to a title with its own different language does not leak it.
 emuenv.cfg.current_config.sys_lang=SCE_SYSTEM_PARAM_LANG_JAPANESE;
 assert(sceAppUtilSystemParamGetInt(SCE_SYSTEM_PARAM_ID_LANG,&value)==0);
 assert(value==SCE_SYSTEM_PARAM_LANG_JAPANESE);
 emuenv.cfg.current_config.sys_lang=SCE_SYSTEM_PARAM_LANG_ENGLISH_US;
 assert(sceAppUtilSystemParamGetInt(SCE_SYSTEM_PARAM_ID_LANG,&value)==0);
 assert(value==SCE_SYSTEM_PARAM_LANG_ENGLISH_US);
 assert(sceAppUtilSystemParamGetInt(SCE_SYSTEM_PARAM_ID_LANG,nullptr)==SCE_APPUTIL_ERROR_PARAMETER);
 std::cout<<"PASS: per-game language reaches guest API, global remains unchanged, switching titles, null output\n";
}
'''
with tempfile.TemporaryDirectory(prefix='linvita-language-test-') as temp:
 path=Path(temp);(path/'test.cpp').write_text(preamble+body+test)
 subprocess.run(['clang++','-std=c++20','-I',str(root/'vita3k/util/include'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
 subprocess.run([str(path/'test')],check=True)
