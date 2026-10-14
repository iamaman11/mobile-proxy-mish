#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "android/app/src/test/java/com/mobileproxymish/app/MishDiagnosticsSerializationTest.kt"
text = PATH.read_text(encoding="utf-8")

old_ctor = '''            rotationTiming = RotationRuntimeTimingView(
                operationId = 9uL,
                operationAgeMs = 17_499uL,
                activatedMs = 7uL,
                preRotationProbeStartedMs = 8uL,
                preRotationProbeCompletedMs = 610uL,
                airplaneEnableStartedMs = 611uL,
                airplaneEnableEffectCompletedMs = 720uL,
                airplaneOnObservedMs = 880uL,
                cellularLossObservedMs = 900uL,
                radioPowerOffObservedMs = 1_400uL,
                airplaneDisableStartedMs = 1_401uL,
                airplaneDisableEffectCompletedMs = 1_520uL,
                airplaneOffObservedMs = 1_650uL,
                cellularRequestRearmStartedMs = 1_651uL,
                cellularRequestRearmCompletedMs = 1_653uL,
                firstPlatformCellularObservationMs = 4_800uL,
                platformCellularObservationsAfterRearm = 2uL,
                freshCellularObservedMs = 5_900uL,
                freshCellularGeneration = 44uL,
                rootAuthorizedMs = 6_300uL,
                rootAuthorizedGeneration = 44uL,
                postRotationProbeStartedMs = 6_301uL,
                postRotationProbeCompletedMs = 7_900uL,
                terminalMs = 7_901uL,
                restoreCompletedMs = null,
            ),
'''
new_ctor = '''            rotationTiming = RotationRuntimeTimingView(
                operationId = 9uL,
                operationAgeMs = 17_499uL,
                activatedMs = 7uL,
                preRotationProbeStartedMs = 8uL,
                preRotationProbeCompletedMs = 610uL,
                mobileDataPreconditionObservedMs = 611uL,
                mobileDataPreconditionEnabled = true,
                dataDisableStartedMs = 612uL,
                dataDisableEffectCompletedMs = 720uL,
                cellularLossObservedMs = 900uL,
                dataEnableStartedMs = 1_401uL,
                dataEnableEffectCompletedMs = 1_520uL,
                freshCellularObservedMs = 5_900uL,
                freshCellularGeneration = 44uL,
                rootAuthorizedMs = 6_300uL,
                rootAuthorizedGeneration = 44uL,
                postRotationProbeStartedMs = 6_301uL,
                postRotationProbeCompletedMs = 7_900uL,
                terminalMs = 7_901uL,
                restoreCompletedMs = null,
            ),
'''
if text.count(old_ctor) != 1:
    raise SystemExit(f"rotation timing fixture drift: {text.count(old_ctor)}")
text = text.replace(old_ctor, new_ctor, 1)

old_assert = '''        assertEquals(9L, rotationTiming.getLong("operation_id"))
        assertEquals(1_400L, rotationTiming.getLong("radio_power_off_observed_ms"))
        assertEquals(1_651L, rotationTiming.getLong("cellular_request_rearm_started_ms"))
        assertEquals(1_653L, rotationTiming.getLong("cellular_request_rearm_completed_ms"))
        assertEquals(4_800L, rotationTiming.getLong("first_platform_cellular_observation_ms"))
        assertEquals(2L, rotationTiming.getLong("platform_cellular_observations_after_rearm"))
        assertEquals(44L, rotationTiming.getLong("fresh_cellular_generation"))
'''
new_assert = '''        assertEquals(9L, rotationTiming.getLong("operation_id"))
        assertEquals(611L, rotationTiming.getLong("mobile_data_precondition_observed_ms"))
        assertTrue(rotationTiming.getBoolean("mobile_data_precondition_enabled"))
        assertEquals(612L, rotationTiming.getLong("data_disable_started_ms"))
        assertEquals(720L, rotationTiming.getLong("data_disable_effect_completed_ms"))
        assertEquals(900L, rotationTiming.getLong("cellular_loss_observed_ms"))
        assertEquals(1_401L, rotationTiming.getLong("data_enable_started_ms"))
        assertEquals(1_520L, rotationTiming.getLong("data_enable_effect_completed_ms"))
        assertEquals(44L, rotationTiming.getLong("fresh_cellular_generation"))
'''
if text.count(old_assert) != 1:
    raise SystemExit(f"rotation timing assertion drift: {text.count(old_assert)}")
text = text.replace(old_assert, new_assert, 1)

for obsolete in (
    "airplaneEnableStartedMs",
    "airplaneEnableEffectCompletedMs",
    "airplaneOnObservedMs",
    "radioPowerOffObservedMs",
    "airplaneDisableStartedMs",
    "airplaneDisableEffectCompletedMs",
    "airplaneOffObservedMs",
    "cellularRequestRearmStartedMs",
    "cellularRequestRearmCompletedMs",
    "firstPlatformCellularObservationMs",
    "platformCellularObservationsAfterRearm",
    '"radio_power_off_observed_ms"',
    '"cellular_request_rearm_started_ms"',
    '"cellular_request_rearm_completed_ms"',
    '"first_platform_cellular_observation_ms"',
    '"platform_cellular_observations_after_rearm"',
):
    if obsolete in text:
        raise SystemExit(f"obsolete diagnostics token remains: {obsolete}")

PATH.write_text(text, encoding="utf-8")
