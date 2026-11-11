#pragma once

#include <array>

// Rotate both accelerometer and gyroscope from the phone's fixed portrait
// axes to the displayed game's axes. Quarter turns match DeviceRotation.
inline std::array<float, 3> rotate_device_sensor(std::array<float, 3> v, int quarter_turns) {
    switch (quarter_turns) {
    case 1: return { -v[1], v[0], v[2] };
    case 2: return { -v[0], -v[1], v[2] };
    case 3: return { v[1], -v[0], v[2] };
    default: return v;
    }
}
