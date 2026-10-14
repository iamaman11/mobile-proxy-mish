#!/usr/bin/env python3
from pathlib import Path

path = Path('android/app/src/test/java/com/mobileproxymish/app/MishDiagnosticsSerializationTest.kt')
text = path.read_text(encoding='utf-8')

old = '''                airplaneEnableStartedMs = 611uL,
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
'''
new = '''                mobileDataPreconditionObservedMs = 611uL,
                mobileDataPreconditionEnabled = true,
                dataDisableStartedMs = 612uL,
                dataDisableEffectCompletedMs = 720uL,
                cellularLossObservedMs = 900uL,
                dataEnableStartedMs = 901uL,
                dataEnableEffectCompletedMs = 1_020uL,
'''
if text.count(old) != 1:
    raise SystemExit(f'old timing fixture count={text.count(old)}')
text = text.replace(old, new, 1)

old_asserts = '''        assertEquals(1_400L, rotationTiming.getLong("radio_power_off_observed_ms"))
        assertEquals(1_651L, rotationTiming.getLong("cellular_request_rearm_started_ms"))
        assertEquals(1_653L, rotationTiming.getLong("cellular_request_rearm_completed_ms"))
        assertEquals(4_800L, rotationTiming.getLong("first_platform_cellular_observation_ms"))
        assertEquals(2L, rotationTiming.getLong("platform_cellular_observations_after_rearm"))
'''
new_asserts = '''        assertEquals(611L, rotationTiming.getLong("mobile_data_precondition_observed_ms"))
        assertTrue(rotationTiming.getBoolean("mobile_data_precondition_enabled"))
        assertEquals(612L, rotationTiming.getLong("data_disable_started_ms"))
        assertEquals(720L, rotationTiming.getLong("data_disable_effect_completed_ms"))
        assertEquals(900L, rotationTiming.getLong("cellular_loss_observed_ms"))
        assertEquals(901L, rotationTiming.getLong("data_enable_started_ms"))
        assertEquals(1_020L, rotationTiming.getLong("data_enable_effect_completed_ms"))
'''
if text.count(old_asserts) != 1:
    raise SystemExit(f'old timing assertions count={text.count(old_asserts)}')
text = text.replace(old_asserts, new_asserts, 1)

for obsolete in (
    'airplaneEnableStartedMs',
    'airplaneEnableEffectCompletedMs',
    'airplaneOnObservedMs',
    'radioPowerOffObservedMs',
    'airplaneDisableStartedMs',
    'airplaneDisableEffectCompletedMs',
    'airplaneOffObservedMs',
    'cellularRequestRearmStartedMs',
    'cellularRequestRearmCompletedMs',
    'firstPlatformCellularObservationMs',
    'platformCellularObservationsAfterRearm',
    'radio_power_off_observed_ms',
    'cellular_request_rearm_started_ms',
    'cellular_request_rearm_completed_ms',
    'first_platform_cellular_observation_ms',
    'platform_cellular_observations_after_rearm',
):
    if obsolete in text:
        raise SystemExit(f'obsolete diagnostics fixture token remains: {obsolete}')

path.write_text(text, encoding='utf-8')
