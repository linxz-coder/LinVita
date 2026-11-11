#include <motion/sensor_rotation.h>
#include <motion/motion_input.h>
#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    // Camera left / right while holding a landscape phone upright. Both must
    // produce neutral horizontal tilt, with gravity along game -Y.
    assert((rotate_device_sensor({ -1, 0, 0 }, 1) == std::array<float, 3>{ 0, -1, 0 }));
    assert((rotate_device_sensor({ 1, 0, 0 }, 3) == std::array<float, 3>{ 0, -1, 0 }));
    assert((rotate_device_sensor({ 0, 1, 0 }, 2) == std::array<float, 3>{ 0, -1, 0 }));
    Util::Quaternion<SceFloat> left_orientation;
    for (float roll : { -0.4f, 0.0f, 0.4f }) {
        const float down = -std::sqrt(1 - roll * roll);
        const auto left = rotate_device_sensor({ down, -roll, 0 }, 1);
        const auto right = rotate_device_sensor({ -down, roll, 0 }, 3);
        assert(left == right && left[0] == roll && left[1] == down);
        MotionInput input;
        input.SetAcceleration({ left[0], left[1], left[2] });
        input.SetGyroscope({ 0, 0, 0 });
        for (int n = 0; n < 120; ++n) input.UpdateOrientation(16667);
        const auto orientation = input.GetOrientation();
        assert(std::isfinite(orientation.w));
        assert(input.GetAcceleration().x == roll);
        if (roll < 0) left_orientation = orientation;
        if (roll > 0) {
            const auto &a = left_orientation;
            const auto &b = orientation;
            const float dot = a.w * b.w + a.xyz.x * b.xyz.x + a.xyz.y * b.xyz.y + a.xyz.z * b.xyz.z;
            assert(std::abs(dot) < 0.999f); // Opposite tilts change the fused pose.
        }
    }
    const std::array<float, 3> rotation_rate{ 0.2f, -0.3f, 0.4f };
    auto v = rotation_rate;
    for (int i = 0; i < 4; ++i) v = rotate_device_sensor(v, 1);
    assert(v == rotation_rate);
    assert((rotate_device_sensor(rotation_rate, 3) == std::array<float, 3>{ -0.3f, -0.2f, 0.4f }));
    std::cout << "PASS: both landscape orientations, upside-down, left/right tilt, gyro axes and finite fusion\n";
}
