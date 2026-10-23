#pragma once
#include "Core.hpp"
#include <iomanip>
#include <vector>

namespace patch {
constexpr uint32_t NamesProperty = 0x73706e6d; // spnm, control-plane metadata only
struct ChannelNames {
    std::vector<std::string> inputs, outputs;
    static constexpr size_t MaxNameBytes = 4096;
    static constexpr size_t MaxPayloadBytes = 2 * MaxChannels * (2 * MaxNameBytes + 4) + 64;
    bool operator==(const ChannelNames& b) const { return inputs == b.inputs && outputs == b.outputs; }
    void validate() const {
        for (const auto* names : {&inputs, &outputs}) {
            if (names->size() > MaxChannels) throw std::invalid_argument("Too many channel names");
            for (const auto& name : *names)
                if (name.size() > MaxNameBytes || name.find('\0') != std::string::npos)
                    throw std::invalid_argument("Invalid channel name");
        }
    }
    std::string encode() const {
        validate();
        std::ostringstream s;
        s << 1 << ' ' << inputs.size() << ' ' << outputs.size();
        for (const auto* names : {&inputs,&outputs}) for (const auto& name : *names) s << ' ' << std::quoted(name);
        return s.str();
    }
    static ChannelNames parse(const std::string& raw) {
        if (raw.size() > MaxPayloadBytes) throw std::invalid_argument("Channel names payload too large");
        std::istringstream s(raw); unsigned version, ins, outs;
        if (!(s >> version >> ins >> outs) || version != 1 || ins > MaxChannels || outs > MaxChannels)
            throw std::invalid_argument("Invalid channel names header");
        ChannelNames n; n.inputs.resize(ins); n.outputs.resize(outs);
        for (auto* names : {&n.inputs,&n.outputs}) for (auto& name : *names) {
            s >> std::ws;
            if (s.peek() != '"' || !(s >> std::quoted(name))) throw std::invalid_argument("Invalid channel name string");
        }
        s >> std::ws;
        if (!s.eof()) throw std::invalid_argument("Trailing channel names data");
        n.validate(); return n;
    }
};
}
