#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace ctrl::mobile {
// Keep the resting value exactly zero and both endpoints exactly +/-1.
inline float axis(int16_t raw) {
    return raw < 0 ? raw / 32768.0f : raw / 32767.0f;
}

inline void radial_deadzone(float &x, float &y, float deadzone, float multiplier) {
    deadzone = std::clamp(deadzone, 0.0f, 0.4f);
    const float length = std::hypot(x, y);
    if (length <= deadzone || length == 0.0f) {
        x = y = 0.0f;
        return;
    }
    const float scale = ((std::min(length, 1.0f) - deadzone) / (1.0f - deadzone)) / length;
    x = std::clamp(x * scale * multiplier, -1.0f, 1.0f);
    y = std::clamp(y * scale * multiplier, -1.0f, 1.0f);
}
} // namespace ctrl::mobile
