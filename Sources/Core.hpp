#pragma once
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>

namespace patch {
constexpr const char* DeviceUID = "se.studiopatch.device.v1";
constexpr const char* BridgeUID = "se.studiopatch.bridge.v1";
constexpr uint32_t ConfigProperty = 0x73706366; // spcf
constexpr uint32_t StatsProperty = 0x73707374; // spst
constexpr uint32_t ReadyProperty = 0x73707264; // sprd
constexpr uint32_t RatesProperty = 0x73707274; // sprt
constexpr uint32_t RateRequestProperty = 0x73707271; // sprq
constexpr uint32_t MaxChannels = 128;
constexpr uint32_t RingFrames = 16384;

struct Config {
    uint32_t inputs = 18, outputs = 18, rate = 96000, delay = 256;
    std::string encode() const {
        return "1 " + std::to_string(inputs) + " " + std::to_string(outputs) + " " +
            std::to_string(rate) + " " + std::to_string(delay);
    }
    static Config parse(const std::string& text) {
        Config c; int version; std::string tail;
        std::istringstream s(text);
        if (!(s >> version >> c.inputs >> c.outputs >> c.rate >> c.delay) ||
            (s >> tail) || version != 1 || c.inputs > MaxChannels ||
            c.outputs > MaxChannels || (c.inputs + c.outputs == 0) ||
            (c.rate < 8000 || c.rate > 384000) ||
            c.delay < 32 || c.delay > 4096)
            throw std::invalid_argument("Invalid channel count, sample rate or transport delay");
        return c;
    }
};

// One writer and multiple readers. Atomic payloads prevent data races on wrap-around.
// Sequential consistency is deliberate in this correctness-first prototype.
// A reader never waits for a writer; missing/overwritten frames become silence.
class Timeline {
    uint32_t channels_;
    std::unique_ptr<std::atomic<uint32_t>[]> samples_;
    std::unique_ptr<std::atomic<int64_t>[]> tags_;
public:
    std::atomic<uint64_t> missingFrames{0};
    explicit Timeline(uint32_t channels) : channels_(channels),
        samples_(new std::atomic<uint32_t>[size_t(RingFrames) * channels]),
        tags_(new std::atomic<int64_t>[RingFrames]) {
        static_assert(std::atomic<uint32_t>::is_always_lock_free);
        static_assert(std::atomic<int64_t>::is_always_lock_free);
        for (size_t i = 0; i < size_t(RingFrames) * channels; ++i) samples_[i].store(0);
        for (uint32_t i = 0; i < RingFrames; ++i) tags_[i].store(-1);
    }
    void write(int64_t frame, const float* data, uint32_t count) noexcept {
        if (frame < 0 || !channels_) return;
        for (uint32_t n = 0; n < count; ++n) {
            const int64_t t = frame + n;
            const size_t slot = uint64_t(t) % RingFrames;
            tags_[slot].store(-1);
            for (uint32_t c = 0; c < channels_; ++c) {
                uint32_t bits; std::memcpy(&bits, &data[size_t(n) * channels_ + c], 4);
                samples_[slot * channels_ + c].store(bits);
            }
            tags_[slot].store(t);
        }
    }
    void read(int64_t frame, float* data, uint32_t count) noexcept {
        if (!channels_) return;
        for (uint32_t n = 0; n < count; ++n) {
            const int64_t t = frame + n;
            const size_t slot = uint64_t(t) % RingFrames;
            float* dest = data + size_t(n) * channels_;
            bool present = t >= 0 && tags_[slot].load() == t;
            if (present) {
                for (uint32_t c = 0; c < channels_; ++c) {
                    uint32_t bits = samples_[slot * channels_ + c].load();
                    std::memcpy(dest + c, &bits, 4);
                }
                present = tags_[slot].load() == t;
            }
            if (!present) {
                std::memset(dest, 0, channels_ * sizeof(float));
                missingFrames.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
};
}
