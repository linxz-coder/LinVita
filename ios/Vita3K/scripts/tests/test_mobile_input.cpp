#include <ctrl/mobile_input.h>
#include <cassert>
#include <cmath>
#include <iostream>
using namespace ctrl::mobile;
int main() {
    assert(axis(0) == 0 && axis(INT16_MIN) == -1 && axis(INT16_MAX) == 1);
    // Typical neutral jitter is silent on both axes, including diagonals.
    for (int i = -2000; i <= 2000; i += 100) {
        float x = axis(i), y = axis(-i);
        radial_deadzone(x, y, .12f, 1);
        assert(x == 0 && y == 0);
    }
    float last = 0;
    for (int i = 0; i <= 32767; ++i) {
        float x = axis(static_cast<int16_t>(i)), y = 0;
        radial_deadzone(x, y, .12f, 1);
        assert(x >= last && x <= 1 && y == 0);
        assert(x - last < .001f); last = x;
    }
    assert(last == 1);
    for (float sign : {-1.f, 1.f}) {
        float x = sign, y = sign;
        radial_deadzone(x, y, .12f, 1);
        assert(std::abs(std::hypot(x,y) - 1) < .0001f);
        assert(x*sign > 0 && y*sign > 0 && x==y);
    }
    float x = -.7f, y = .4f;
    radial_deadzone(x,y,0,1);
    assert(std::abs(x+.7f)<.0001f && std::abs(y-.4f)<.0001f);
    std::cout << "PASS: neutral jitter, full travel, smooth deadzone, quadrants, disabled deadzone\n";
}
