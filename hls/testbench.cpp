// SPDX-License-Identifier: GPL-3.0-only
#include "xp3_voice.h"
#include "xp3_core.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <stdexcept>

using Row=std::map<std::string,std::string>;
std::vector<std::string> split(const std::string& text) {
    std::vector<std::string> out; std::istringstream stream(text); std::string value;
    while (std::getline(stream,value,',')) { if (!value.empty() && value.back()=='\r') value.pop_back(); out.push_back(value); }
    return out;
}
struct Csv {
    std::ifstream input; std::vector<std::string> header;
    explicit Csv(const std::string& path):input(path) { std::string line; if (!std::getline(input,line)) throw std::runtime_error("Missing/empty CSV: "+path); header=split(line); }
    bool next(Row& row) { std::string line; if (!std::getline(input,line)) return false; auto values=split(line); if (values.size()!=header.size()) throw std::runtime_error("Truncated CSV"); row.clear(); for (size_t i=0;i<header.size();++i) row[header[i]]=values[i]; return true; }
};
uint64_t number(const Row& row,const std::string& name) { return std::stoull(row.at(name)); }
int fieldIndex(const std::string& name) { for (unsigned i=0;i<51;++i) if (name==xp3::voiceFieldNames[i]) return i; throw std::runtime_error("Unknown Voice field: "+name); }
void seed(const Row& row,uint32_t* state,uint32_t* context) {
    for (unsigned slot=0;slot<2;++slot) for (unsigned i=0;i<51;++i) state[slot*51+i]=static_cast<uint32_t>(number(row,"voice["+std::to_string(slot)+"]."+xp3::voiceFieldNames[i]));
    uint64_t clock=number(row,"sampleClock"); context[0]=clock; context[1]=clock>>32;
    context[2]=number(row,"irqStatus"); context[3]=number(row,"irqConfigMask"); context[4]=number(row,"interrupt"); context[6]=number(row,"irqBlockedEvent");
    for (unsigned cs=0;cs<8;++cs) context[7+cs]=number(row,"waveRomConfig["+std::to_string(cs)+"]");
}
void event(const Row& row,uint32_t* state,uint32_t* context) {
    const std::string kind=row.at("event"); const uint32_t value=number(row,"value");
    if (kind.find("voice[")==0) state[std::stoul(kind.substr(6))*51+fieldIndex(kind.substr(9))]=value;
    else if (kind=="irqStatus") context[2]=value;
    else if (kind=="irqConfigMask") context[3]=value;
    else if (kind=="interrupt") context[4]=value;
    else if (kind.find("waveRomConfig[")==0) context[7+std::stoul(kind.substr(14))]=value;
    else if (kind=="hostRead") context[4]=0;
    else if (kind=="releaseMask") {
        const int shadow=fieldIndex("resetState_3900.shadow"),released=fieldIndex("resetState_3900.released"),phase=fieldIndex("runtimeCache.runtimePhase");
        if (state[shadow] && !value) { state[released]=0; state[phase]=0; } state[shadow]=value!=0;
    } else if (kind=="commitRelease") {
        const int shadow=fieldIndex("resetState_3900.shadow"),released=fieldIndex("resetState_3900.released");
        if (state[shadow] && !state[released]) { state[released]=1; state[fieldIndex("runtimeCache.runtimePhase")]=1; }
    } else if (kind=="powerReset") {
        for (unsigned i=0;i<102;++i) state[i]=0;
        for (unsigned i=0;i<15;++i) context[i]=0;
    } else throw std::runtime_error("Unknown input event: "+kind);
}
uint64_t observed(const std::string& name,uint64_t frame,const uint32_t* state,const uint32_t* context) {
    if (name=="frame") return frame;
    if (name=="sampleClock") return uint64_t(context[0])|(uint64_t(context[1])<<32);
    if (name=="irqStatus") return context[2]; if (name=="irqConfigMask") return context[3];
    if (name=="interrupt") return context[4]; if (name=="irqBlockedEvent") return context[6];
    if (name.find("waveRomConfig[")==0) return context[7+std::stoul(name.substr(14))];
    if (name.find("voice[")==0) { const auto slot=std::stoul(name.substr(6)); const auto member=name.substr(name.find("].")+2); return state[slot*51+fieldIndex(member)]; }
    throw std::runtime_error("Unknown expected column: "+name);
}

int main(int argc,char** argv) {
    try {
        if (argc<3 || argc>4) throw std::runtime_error("Usage: xp3_testbench GOLDEN_DIR RESULT_DIR [state|rom|timing]");
        const std::string root=argv[1],destination=argv[2],mutation=argc==4 ? argv[3] : "";
        Csv manifest(root+"/manifest.csv"); Row entry; uint64_t frames=0,cases=0,fetches=0;
        while (manifest.next(entry)) {
            const auto name=entry.at("case"),dir=root+"/"+name;
            uint32_t state[102]={},context[40]={},audio[4]={};
            Csv initial(dir+"/initial.csv"); Row initialRow; if (!initial.next(initialRow)) throw std::runtime_error("Missing initial state"); seed(initialRow,state,context);
            for (unsigned cs=0;cs<8;++cs) { context[15+cs]=number(entry,"rom_size"+std::to_string(cs)); context[23+cs]=number(entry,"rom_flags"+std::to_string(cs)); }
            Csv inputs(dir+"/events.csv"),expected(dir+"/expected.csv"),reads(dir+"/rom-reads.csv"),stages(dir+"/stages.csv");
            Row input,read,stage,golden; bool hasInput=inputs.next(input),hasRead=reads.next(read),hasStage=stages.next(stage);
            std::ofstream out(destination+"/"+name+".csv"); out.exceptions(std::ios::badbit|std::ios::failbit);
            for (unsigned i=0;i<expected.header.size();++i) { if(i) out<<','; out<<expected.header[i]; } out<<'\n';
            unsigned count=0;
            while (expected.next(golden)) {
                const uint64_t frame=number(golden,"frame");
                if (frame!=count+number(entry,"start_frame")) throw std::runtime_error("Noncontiguous golden frame");
                while (hasInput && number(input,"frame")==frame) { event(input,state,context); hasInput=inputs.next(input); }
                context[5]=context[6]=0;
                std::vector<Row> requestsForFrame;
                while (hasRead && number(read,"frame")==frame) { requestsForFrame.push_back(read); hasRead=reads.next(read); }
                std::map<unsigned,int32_t> interpolated;
                while (hasStage && number(stage,"frame")==frame) { if (stage.at("stage")=="interpolation") interpolated[number(stage,"voice")]=static_cast<int32_t>(std::stoll(stage.at("b"))); hasStage=stages.next(stage); }
                if (mutation=="state" && name=="fce_dpcm" && frame==8) state[fieldIndex("dpcmAccumulator_0c00")]^=1;
                const bool paired=name.find("pair_structure_")==0;
                int32_t source[2]={}; bool due[2]={};
                for (unsigned slot=0;slot<(paired ? 2u : number(entry,"slots"));++slot) {
                    hls::stream<uint32_t> requests; hls::stream<uint8_t> replies; std::vector<uint32_t> addresses;
                    for (const auto& r:requestsForFrame) if (number(r,"voice")==slot) {
                        const unsigned cs=number(r,"chip_select"),address=number(r,"physical_address");
                        if (address<context[15+cs]) { addresses.push_back((cs<<24)|address); uint8_t value=number(r,"value"); if (mutation=="rom" && name=="fce_dpcm" && frame==0 && addresses.size()==1) value^=1; replies.write(value); }
                    }
                    const bool moveClock=mutation=="timing" && name=="fractional_pitch" && frame>=3;
                    if (moveClock) ++context[0];
                    xp3_voice_step(state,context,(paired ? 1u : 0u)|(slot<<16)|((slot+number(entry,"first_voice"))<<8),audio,requests,replies);
                    if (moveClock) --context[0];
                    source[slot]=static_cast<int32_t>(audio[0]); due[slot]=audio[1]!=0;
                    if (due[slot] != (interpolated.count(slot)!=0) || (due[slot] && source[slot]!=interpolated.at(slot))) throw std::runtime_error(name+" frame="+std::to_string(frame)+" field=interpolated sample");
                    for (uint32_t address:addresses) { if (requests.empty() || requests.read()!=address) throw std::runtime_error(name+" frame="+std::to_string(frame)+" ROM address/order mismatch"); ++fetches; }
                    if (!requests.empty() || !replies.empty()) throw std::runtime_error(name+" frame="+std::to_string(frame)+" ROM response/request count mismatch");
                }
                if (paired && (due[0] || due[1])) { hls::stream<uint32_t> requests; hls::stream<uint8_t> replies; audio[0]=due[0] ? source[0] : 0; audio[1]=due[1] ? source[1] : 0; xp3_voice_step(state,context,2,audio,requests,replies); }
                uint64_t clock=(uint64_t(context[0])|(uint64_t(context[1])<<32))+1; context[0]=clock; context[1]=clock>>32;
                for (unsigned i=0;i<expected.header.size();++i) { const auto& key=expected.header[i]; const uint64_t actual=observed(key,frame,state,context),reference=number(golden,key); if(i) out<<','; out<<actual; if(actual!=reference) throw std::runtime_error(name+" frame="+std::to_string(frame)+" field="+key+" reference="+std::to_string(reference)+" actual="+std::to_string(actual)); }
                out<<'\n'; ++count; ++frames;
            }
            if (count!=number(entry,"frames") || hasInput || hasRead || hasStage) throw std::runtime_error("Truncated cases/events: "+name);
            ++cases; std::cout<<"XP3_CASE_PASS "<<name<<" frames="<<count<<'\n';
        }
        if (cases!=61 || frames!=271360) throw std::runtime_error("Incomplete test suite");
        std::cout<<"XP3_TESTBENCH_COMPLETE cases="<<cases<<" frames="<<frames<<" ROM_requests="<<fetches<<" max_error=0\n";
        return 0;
    } catch(const std::exception& error) { std::cerr<<"XP3_FIRST_DIFFERENCE "<<error.what()<<'\n'; return 1; }
}
