#!/usr/bin/env python3
"""Small independent oracle for ECSS 5.4.5 through 5.4.7."""

from __future__ import annotations

from collections import deque


FIRST_NULL_BITS = (0, 1, 1, 1, 0, 1, 0, 0, 0)


def ds_encode(bits: tuple[int, ...]) -> list[tuple[int, int]]:
    data = 0
    strobe = 0
    result = []
    for bit in bits:
        if bit == data:
            strobe ^= 1
        else:
            data = bit
        result.append((data, strobe))
    return result


class NullParityGuard:
    def __init__(self) -> None:
        self.rx_enable = False
        self.got_null = False
        self._window: deque[int] = deque(maxlen=len(FIRST_NULL_BITS))

    def enable(self) -> None:
        self.rx_enable = True

    def disable(self) -> None:
        self.rx_enable = False
        self.got_null = False
        self._window.clear()

    def feed_bit(self, bit: int) -> None:
        if not self.rx_enable or self.got_null:
            return
        self._window.append(bit)
        if tuple(self._window) == FIRST_NULL_BITS:
            self.got_null = True

    def parity_error(self, raw_error: bool) -> bool:
        return self.rx_enable and self.got_null and raw_error


def self_check() -> None:
    waveform = ds_encode(FIRST_NULL_BITS)
    assert waveform[0] == (0, 1), "first Null transition must be on Strobe"

    guard = NullParityGuard()
    guard.enable()
    assert not guard.parity_error(True), "parity error must be gated before gotNull"
    for bit in FIRST_NULL_BITS[:-1]:
        guard.feed_bit(bit)
        assert not guard.got_null, "gotNull asserted before all three parity bits"
    guard.feed_bit(FIRST_NULL_BITS[-1])
    assert guard.got_null, "complete first Null was not detected"
    assert guard.parity_error(True), "parity error must be visible after gotNull"
    guard.disable()
    assert not guard.got_null and not guard.parity_error(True), "RX disable must clear gotNull"
    print("ENCODING_GOLDEN|PASS|first_null=011101000 gotNull_hold_clear=1 parity_gate=1")


if __name__ == "__main__":
    self_check()
