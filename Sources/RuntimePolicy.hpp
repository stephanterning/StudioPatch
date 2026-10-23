#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <stdexcept>
#include <vector>

namespace patch {
// Pure control-plane policy. The audio callback never executes these decisions.
// A client request remains authoritative until completed or superseded; polling
// an old hardware rate must not turn it into an opposite synchronization request.
struct RuntimePolicy {
    enum class Phase { waiting, preparing, running, silentFailure };
    struct Request { uint64_t generation; double rate; };
    Phase phase = Phase::waiting;
    uint64_t generation = 0;
    double requestedRate = 0;
    std::string failure;
    unsigned failures = 0;

    Request request(double rate) {
        if (!std::isfinite(rate) || rate <= 0) throw std::invalid_argument("Invalid sample rate");
        requestedRate = rate;
        ++generation;
        phase = Phase::preparing;
        failures = 0;
        failure.clear();
        return {generation, rate};
    }
    bool current(Request r) const { return r.generation == generation && r.rate == requestedRate; }
    bool complete(Request r, const std::vector<double>& actualRates) {
        if (!current(r)) return false;
        if (actualRates.empty() || std::any_of(actualRates.begin(), actualRates.end(),
            [&](double rate) { return !std::isfinite(rate) || std::abs(rate-r.rate) >= 0.1; })) return false;
        phase = Phase::running;
        failure.clear(); failures = 0;
        return true;
    }
    // Initial attempt plus three immediate retries, then five-second intervals.
    unsigned fail(Request r, const std::string& reason) {
        if (!current(r)) return 0;
        phase = Phase::silentFailure;
        failure = reason;
        return ++failures <= 3 ? 0 : 5000;
    }
    void unavailable(const std::string& reason) {
        ++generation; phase = Phase::waiting; failure = reason; failures = 0;
    }
    bool mayRoute() const { return phase == Phase::running; }
};
}
