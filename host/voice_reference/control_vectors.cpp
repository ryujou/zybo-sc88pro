// SPDX-License-Identifier: GPL-3.0-only
#include "custom_chips/xp/xp_voice_common.h"
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>

int main(int argc,char** argv)
{
    try
    {
        if(argc!=2) throw std::runtime_error("Usage: sc88_control_vectors OUTPUT_FILE");
        std::ofstream out(argv[1]); out.exceptions(std::ios::badbit|std::ios::failbit);
        for(uint32_t pitch=0;pitch<0x40000;++pitch)
            out<<"0 "<<pitch<<" 0 0 0 "<<xpLib::xpInternal::decodePitch(pitch)<<'\n';
        std::mt19937 random(0x88c);
        for(unsigned i=0;i<32768;++i)
        {
            xpLib::XP::VoiceState v{};
            v.ampCurrent_1e00=random()&0x3ffff; v.ampModCurrent_1d00=random()&0x3ffff;
            if(i<16) { v.ampCurrent_1e00=i&2 ? 0x3ffff : 0; v.ampModCurrent_1d00=i&4 ? 0x3ffff : 0; }
            v.ampModRamp_1900=(i&1) ? 0x4000 : 0;
            out<<"1 0 "<<v.ampCurrent_1e00<<' '<<v.ampModCurrent_1d00<<' '<<(i&1)<<' '<<xpLib::xpInternal::combineAmp(v)<<'\n';
        }
        std::cout<<"CONTROL_VECTORS_COMPLETE count=294912\n";
        return 0;
    }
    catch(const std::exception& error) { std::cerr<<error.what()<<'\n'; return 1; }
}
