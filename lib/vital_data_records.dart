import 'dart:math';
import 'dart:math' as Math;

/// Holds a single record of vital signs data from the device.
class VitalDataRecord {
  // Signals from user's original data:
  final int spo2;
  final int heartRate;  // Maps to 'pulse' signal
  final List<double> ppgSignal;
  final List<double> ecgSignal;

  // New signals added to match the 10-signal EDF header:
  final int battery;
  final int chargeState;
  final int signalQuality;
  final int sensorStatus;
  final double hrv;             // heart_rate_varia
  final double derivedEffort;
  final double derivedFlow;

  VitalDataRecord({
    this.spo2 = 99,
    this.heartRate = 70,
    this.ppgSignal = const [],
    this.ecgSignal = const [],
    // Defaults for new fields
    this.battery = 90,
    this.chargeState = 0, // 0=Discharging, 1=Charging
    this.signalQuality = 100,
    this.sensorStatus = 0, // 0=Attached
    this.hrv = 50.0,
    this.derivedEffort = 0.0,
    this.derivedFlow = 0.0,
  });

}