#!/bin/bash
# Hook: after any rtl/*.sv or tb/*.sv file is saved, run the full RTL regression.
#
# Rewritten 2026-09-05 for the spacewire repo's actual layout (flat rtl/ + tb/,
# no spacewire/testbench/ subpath — the old spec2rtl-root version of this script
# assumed a nested spacewire/spacefibre monorepo structure that no longer exists
# after the repo split).
#
# IMPORTANT: use -g2005-sv, NOT -g2012. Icarus Verilog 12.0 has a codegen bug
# under -g2012 that corrupts vvp bytecode for multi-instance testbenches
# (tb_credit_boundary_multipacket, tb_credit_boundary_top, tb_esc_enc_handshake,
# tb_spw_top_loopback all failed with a spurious "syntax error" at the vvp
# bytecode level under -g2012; -g2005-sv compiles the same SystemVerilog fine).
# Confirmed by direct iverilog re-run, 2026-09-05.

CHANGED_FILE="$1"
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "$PROJECT_ROOT" || exit 0

LOG_DIR="$PROJECT_ROOT/.claude/logs"
BUILD_DIR="$PROJECT_ROOT/.claude/build"
mkdir -p "$LOG_DIR" "$BUILD_DIR"

{
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "▶ post-edit-sv: $CHANGED_FILE changed @ $(date '+%Y-%m-%d %H:%M:%S') — running RTL regression"
} | tee -a "$LOG_DIR/post-edit.log"

if ! command -v iverilog &>/dev/null; then
  echo "⚠ iverilog not found — skipping RTL regression for $CHANGED_FILE" | tee -a "$LOG_DIR/post-edit.log"
  exit 0
fi

# Returns 0 (pass) / 1 (fail) by inspecting a vvp run's captured output.
# This project's testbenches use varying summary formats ("ALL ... PASSED",
# "N checks, 0 FAILED", "[PASS] ..." lines) — no single fixed string works for
# all of them, so treat an explicit [FAIL] or a nonzero "<N> FAILED" count as
# failure, and require at least one PASS-ish marker to call it a pass. Silence
# (no PASS marker at all) is treated as failure rather than assumed success.
check_pass() {
  local log="$1"
  grep -qiE '\[fail\]' "$log" && return 1
  grep -qiE '[1-9][0-9]* +failed' "$log" && return 1
  grep -qiE 'pass' "$log" && return 0
  return 1
}

RTL_TBS="tb_fsm_smoke tb_esc_rx tb_credit tb_priority tb_err_reset tb_phy \
         tb_esc_enc_handshake tb_spw_top_loopback tb_credit_boundary_top \
         tb_credit_boundary_multipacket tb_race_check tb_eep_recovery \
         tb_tx_flush_recovery tb_decision17_tc_starvation"

PASS=0
FAIL=0
FAILED_NAMES=""

for tb in $RTL_TBS; do
  vvp_bin="$BUILD_DIR/${tb}.vvp"
  run_log="$BUILD_DIR/${tb}.run.log"
  if iverilog -g2005-sv -o "$vvp_bin" rtl/*.sv "tb/${tb}.sv" > "$BUILD_DIR/${tb}.compile.log" 2>&1; then
    vvp "$vvp_bin" > "$run_log" 2>&1
    if check_pass "$run_log"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      FAILED_NAMES="$FAILED_NAMES $tb"
    fi
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES ${tb}(compile)"
  fi
done

# Standalone unit TBs compile against a single RTL module, not the full rtl/*.sv set.
for pair in "tb_spw_enc_standalone:spw_enc.sv" "tb_spw_network_standalone:spw_network.sv"; do
  tb="${pair%%:*}"
  src="${pair##*:}"
  vvp_bin="$BUILD_DIR/${tb}.vvp"
  run_log="$BUILD_DIR/${tb}.run.log"
  if iverilog -g2005-sv -o "$vvp_bin" "rtl/${src}" "tb/${tb}.sv" > "$BUILD_DIR/${tb}.compile.log" 2>&1; then
    vvp "$vvp_bin" > "$run_log" 2>&1
    if check_pass "$run_log"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      FAILED_NAMES="$FAILED_NAMES $tb"
    fi
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES ${tb}(compile)"
  fi
done

{
  if [ "$FAIL" -gt 0 ]; then
    echo "✗ Result: $PASS passed, $FAIL failed —$FAILED_NAMES"
    echo "  See $BUILD_DIR/<name>.run.log / <name>.compile.log for details"
  else
    echo "✓ Result: $PASS/$PASS RTL testbenches passed"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} | tee -a "$LOG_DIR/post-edit.log"

# Informational only — PostToolUse fires after the edit already happened, so
# there is nothing left to block. Non-zero exit here would just be noise.
exit 0
