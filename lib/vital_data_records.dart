/// Holds a single record of vital signs data from the device.
class VitalDataRecord {
  // Signals from user's original data:
  final int spo2;
  final int heartRate; // Maps to 'pulse' signal
  final List<double> ppgSignal;
  final List<double> ecgSignal;

  // New signals added to match the 10-signal EDF header:
  final int battery;
  final int chargeState;
  final int signalQuality;
  final int sensorStatus;
  final double hrv; // heart_rate_varia
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
    this.hrv = 0,
    this.derivedEffort = 0.0,
    this.derivedFlow = 0.0,
  });

  /// Converts this object to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'spo2': spo2,
      'heartRate': heartRate,
      'ppgSignal': ppgSignal,
      'ecgSignal': ecgSignal,
      'battery': battery,
      'chargeState': chargeState,
      'signalQuality': signalQuality,
      'sensorStatus': sensorStatus,
      'hrv': hrv,
      'derivedEffort': derivedEffort,
      'derivedFlow': derivedFlow,
    };
  }

  VitalDataRecord copyWith({
    int? spo2,
    int? heartRate,
    List<double>? ppgSignal,
    List<double>? ecgSignal,
    int? battery,
    int? chargeState,
    int? signalQuality,
    int? sensorStatus,
    double? hrv,
    double? derivedEffort,
    double? derivedFlow,
  }) {
    return VitalDataRecord(
      spo2: spo2 ?? this.spo2,
      heartRate: heartRate ?? this.heartRate,
      ppgSignal: ppgSignal ?? this.ppgSignal,
      ecgSignal: ecgSignal ?? this.ecgSignal,
      battery: battery ?? this.battery,
      chargeState: chargeState ?? this.chargeState,
      signalQuality: signalQuality ?? this.signalQuality,
      sensorStatus: sensorStatus ?? this.sensorStatus,
      hrv: hrv ?? this.hrv,
      derivedEffort: derivedEffort ?? this.derivedEffort,
      derivedFlow: derivedFlow ?? this.derivedFlow,
    );
  }
}
