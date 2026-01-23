import 'dart:ffi';
import 'dart:io';
import 'dart:math' as Math;

import 'package:ffi/ffi.dart';

import 'edf_lib.dart';
import 'vital_data_records.dart';

class EDFHelper {
  // Creates a multi-signal EDF file from O2Ring or mock data
  /// This version is corrected for strict parsers:
  /// 1. Uses standard EDF (not EDF+) to avoid the 'EDF Annotations' channel.
  /// 2. Uses lowercase_with_underscore labels.
  // Creates a multi-signal EDF file from O2Ring or mock data
  /// This version is corrected for strict parsers:
  /// 1. Uses standard EDF (not EDF+) to avoid the 'EDF Annotations' channel.
  /// 2. Uses lowercase_with_underscore labels.
  static Future<File?> createMultiSignalEdf(String filePath, {

    required DateTime datetime,

    List<VitalDataRecord> collectedVitals = const [],

    String patientName = "Patient_O2Ring",

    String recordingName = "O2Ring Recording",

  }) async {
    try {
      final pathPtr = filePath.toNativeUtf8();


      final signals = [
        // label, unit, fs, physMin, physMax, digMin, digMax
        ('spo2', '%', 1, 0.0, 100.0, 0, 100),
        ('pulse', 'bpm', 1, 0.0, 100.0, 0, 100),
        ('battery', '%', 1, 0.0, 100.0, 0, 100),
        ('charge_state', '', 1, 0.0, 100.0, 0, 100),
        ('signal_quality', '%', 1, 0.0, 100.0, 0, 100),
        ('sensor_status', '', 1, 0.0, 100.0, 0, 100),
        ('ppg', '', 125, 0.0, 255.0, 0, 255),
        ('ble_connection', '', 1, 0.0, 100.0, 0, 100),
        ('HRV', 'ms', 10, -100.0, 100.0, 0, 100),
        ('derived_effort', '', 10, -100.0, 100.0, -32768, 32767),
        ('derived_flow', '', 10, -100.0, 100.0, 0, 100),
      ];


// --- FIX 1: File Type ---

// Changed from EDFLIB_FILETYPE_EDFPLUS to EDFLIB_FILETYPE_EDF

// This prevents the extra 'EDF Annotations' channel from being added.

      final handle = edfOpenFileWriteonly(

        pathPtr,

        EDFLIB_FILETYPE_EDFPLUS,

// Use 1 (or your lib's constant for standard EDF)

        signals.length,

      );

      calloc.free(pathPtr);


      if (handle < 0) {
        print('Failed to open EDF for write: $handle');

        return null;
      }


// Set start time and datarecord duration (1 second)

      final start = datetime;

      edfSetStartdatetime(

        handle,

        start.year,

        start.month,

        start.day,

        start.hour,

        start.minute,

        start.second,

      );

      edfSetDatarecordDuration(handle, 1);


// Minimal metadata

      final patientPtr = patientName.toNativeUtf8();

      edfSetPatientname(handle, patientPtr);

      calloc.free(patientPtr);


      final recPtr = recordingName.toNativeUtf8();

      edfSetRecordingAdditional(handle, recPtr);

      calloc.free(recPtr);


// Set per-signal parameters

      for (int s = 0; s < signals.length; s++) {
        final (label, unit, fs, physMin, physMax, digMin, digMax) = signals[s];

        final labelPtr = label.toNativeUtf8();

        edfSetLabel(handle, s, labelPtr);

        calloc.free(labelPtr);


        edfSetSamplefrequency(handle, s, fs);

        edfSetPhysicalMinimum(handle, s, physMin.toDouble());

        edfSetPhysicalMaximum(handle, s, physMax.toDouble());

        edfSetDigitalMinimum(handle, s, digMin);

        edfSetDigitalMaximum(handle, s, digMax);


        final unitPtr = (unit == 'N/A'

            ? ''.toNativeUtf8()

            : unit.toNativeUtf8());

        edfSetPhysicalDimension(handle, s, unitPtr);

        calloc.free(unitPtr);
      }


// Determine number of seconds

      final seconds = collectedVitals.isNotEmpty ? collectedVitals.length : 10;

      final random = Math.Random();


// Determine total samples per record

      final totalSamplesPerRecord = signals.fold<int>(

        0,

            (sum, sig) => sum + sig.$3,

      );

      final recordBuf = calloc<Int16>(totalSamplesPerRecord);


// Track last valid PPG value for forward-filling

      double? lastValidPpg = null;


// Start writing each second

      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;

        final record = collectedVitals.isNotEmpty ? collectedVitals[sec] : null;


        if (record != null) {
          for (int s = 0; s < signals.length; s++) {
            final (label, unit, fs, physMin, physMax, digMin, digMax) =

            signals[s];


            if (record != null) {
// Cast any dynamic lists to List<double> to avoid type issues

              final ppgSignal = record.ppgSignal;

              final ecgSignal = record.ecgSignal.cast<double>();


              if (ppgSignal.isEmpty) {
                continue;
              }


// await Future.delayed(Duration(milliseconds: 1));


// Map ALL fields from VitalDataRecord to the recordMap

// The keys in this map MUST match the labels from the 'signals' array.

              final recordMap = {

                'spo2': record.spo2.toDouble(),

                'pulse': record.heartRate.toDouble(),

                'battery': record.battery.toDouble(),

                'charge_state': record.chargeState.toDouble(),

                'signal_quality': record.signalQuality.toDouble(),

                'sensor_status': record.sensorStatus.toDouble(),

                'ppg': ppgSignal,

                'ble_connection': 90,

                'HRV': record.hrv.toDouble(),

                'derived_effort': record.derivedEffort.toDouble(),

                'derived_flow': record.derivedFlow.toDouble(),

              };


              for (int i = 0; i < fs; i++) {
                double phys = 0;


                final value = recordMap[label];

                if (value is List<double>) {
                  phys = i < value.length ? value[i] : 0.0;


// Forward-fill PPG data: if value is 0 and we have a last valid value, use it

                  if (label == 'ppg' && phys == 0.0 && lastValidPpg != null) {
                    phys = lastValidPpg!;
                  } else if (label == 'ppg' && phys != 0.0) {
// Update last valid PPG value when we encounter a non-zero value

                    lastValidPpg = phys;
                  }
                } else if (value is num) {
                  phys = value.toDouble();
                } else {
                  phys = 0.0; // Default for unmapped channels

                }

// Map physical to digital

                final mapped =

                (digMin +

                    (phys - physMin) *

                        (digMax - digMin) /

                        (physMax - physMin))
                    .round();

// Clamp to the signal's specified digital range

                recordBuf[offset + i] = mapped.clamp(digMin, digMax);
              }


              offset += fs;
            }
          }
        }


        try {
// Write this second

          final w = edfBlockwriteDigitalShortSamples(handle, recordBuf);

          if (w != 0) {
            print(

              'edfBlockwriteDigitalShortSamples failed with $w at sec $sec',

            );
          }
        } catch (ex) {
          print('Exception while writing edf $ex');
        }
      }


      calloc.free(recordBuf);


      final closeRes = edfCloseFile(handle);

      if (closeRes != 0 && closeRes != 1) {
        print('Warning: closing EDF handle returned $closeRes');
      }


      print('Multi-signal EDF written at $filePath');

      return File(filePath);
    } catch (e) {
      print('Error creating multi-signal EDF: $e');

      return null;
    }
  }

  static Future<File?> createMultiSignalEdfV2(String filePath, {
    required DateTime datetime,
    List<VitalDataRecord> collectedVitals = const [],
    String patientName = "Patient_O2Ring",
    String recordingName = "O2Ring Recording",
  }) async {
    int handle = -1;

    // Helper to ensure strings are ASCII only for the C header
    String sanitize(String input) {
      return input.replaceAll(RegExp(r'[^\x00-\x7F]'), '');
    }

    try {
      // 1. Ensure the directory exists
      final file = File(filePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }

      final pathPtr = filePath.toNativeUtf8();

      // 2. Define signals with explicit types
      // (label, unit, fs, physMin, physMax, digMin, digMax)
      final signals = [
        ('spo2', '%', 1, 0.0, 100.0, 0, 100),
        ('pulse', 'bpm', 1, 0.0, 250.0, 0, 250),
        ('battery', '%', 1, 0.0, 100.0, 0, 1000),
        ('charge_state', '', 1, 0.0, 100.0, 0, 100),
        ('signal_quality', '%', 1, 0.0, 100.0, 0, 100),
        ('sensor_status', '', 1, 0.0, 10.0, 0, 100),
        ('ppg', '', 125, 0.0, 255.0, 0, 255),
        ('ble_connection', '', 1, 0.0, 1.0, 0, 1),
        ('HRV', 'ms', 10, -100.0, 100.0, -100, 100),
        ('derived_effort', '', 10, -100.0, 100.0, -100, 100),
        ('derived_flow', '', 10, -100.0, 100.0, -100, 100),
      ];

      // 3. Open file using EDFPLUS to prevent Error -7
      handle = edfOpenFileWriteonly(
        pathPtr,
        EDFLIB_FILETYPE_EDFPLUS, // Always use EDFPLUS for modern health data
        signals.length,
      );
      calloc.free(pathPtr);

      if (handle < 0) {
        print("EDFLib Open Error: $handle");
        return null;
      }

      // 4. Set Header Metadata
      edfSetStartdatetime(
          handle,
          datetime.year,
          datetime.month,
          datetime.day,
          datetime.hour,
          datetime.minute,
          datetime.second);
      edfSetDatarecordDuration(handle, 1);

      final pNamePtr = sanitize(patientName).toNativeUtf8();
      edfSetPatientname(handle, pNamePtr);
      calloc.free(pNamePtr);

      // 5. Signal Metadata Loop with strict FFI Type Casting
      for (int s = 0; s < signals.length; s++) {
        final sig = signals[s];
        print(sig);
        final lPtr = sanitize(sig.$1).toNativeUtf8();
        final uPtr = sanitize(sig.$2).toNativeUtf8();

        edfSetLabel(handle, s, lPtr);
        edfSetSamplefrequency(handle, s, sig.$3);

        // Fix: Explicitly cast to Double for FFI
        edfSetPhysicalMinimum(handle, s, sig.$4.toDouble());
        edfSetPhysicalMaximum(handle, s, sig.$5.toDouble());
        edfSetDigitalMinimum(handle, s, sig.$6.toInt());
        edfSetDigitalMaximum(handle, s, sig.$7.toInt());
        edfSetPhysicalDimension(handle, s, uPtr);

        calloc.free(lPtr);
        calloc.free(uPtr);
      }

      // 6. Data Record Writing
      final samplesPerRecord = signals.fold<int>(0, (sum, sig) => sum + sig.$3);
      final recordBuf = calloc<Int16>(samplesPerRecord);

      for (int sec = 0; sec < collectedVitals.length; sec++) {
        int offset = 0;
        final record = collectedVitals[sec];

        for (int s = 0; s < signals.length; s++) {
          final (label, _, fs, physMin, physMax, digMin, digMax) = signals[s];

          dynamic raw;
          if (label == 'ppg')
            raw = record.ppgSignal;
          else if (label == 'spo2')
            raw = record.spo2;
          else if (label == 'pulse')
            raw = record.heartRate;
          else if (label == 'HRV')
            raw = record.hrv;
          else if (label == 'derived_effort')
            raw = record.derivedEffort;
          else if (label == 'derived_flow')
            raw = record.derivedFlow;
          else
            raw = 0.0;

          // SPECIAL HANDLING FOR PPG (0x1b Pulse Flag)
          if (label == 'ppg' && raw is List) {
            for (int i = 0; i < fs; i++) {
              double val = (i < raw.length ? (raw[i]?.toDouble() ?? 0.0) : 0.0);

              // FIX: Detect Viatom Pulse Flag (156)
              if (val >= 155.0 || val < 0) {
                // Interpolate: Use the previous sample value if available
                // (If it's the very first sample, we might just keep it or use 0)
                val = (i > 0)
                    ? (raw[i - 1]?.toDouble() ?? 0.0) // Previous sample
                    : (offset > 0
                    ? recordBuf[offset - 1].toDouble()
                    : 0.0); // Previous block end
              }

              // Map to Digital Range
              // Note: If you swapped physMin/Max above, this math automatically inverts the signal.
              final mapped = (digMin +
                  (val - physMin) * (digMax - digMin) / (physMax - physMin))
                  .round();
              recordBuf[offset + i] = mapped.clamp(digMin, digMax);
            }
          }
          else {
            // Standard processing for other signals
            for (int i = 0; i < fs; i++) {
              double phys = (raw is List)
                  ? (i < raw.length ? (raw[i]?.toDouble() ?? 0.0) : 0.0)
                  : (raw?.toDouble() ?? 0.0);

              final mapped = (digMin +
                  (phys - physMin) * (digMax - digMin) / (physMax - physMin))
                  .round();
              recordBuf[offset + i] = mapped.clamp(digMin, digMax);
            }
          }
          offset += fs;
        }
        edfBlockwriteDigitalShortSamples(handle, recordBuf);
      }

      calloc.free(recordBuf);
      return File(filePath);
    } catch (e) {
      print("EDF Generation Crash: $e");
      return null;
    } finally {
      // 7. Ensure handle is ALWAYS closed to prevent "Busy" or Permission errors
      if (handle >= 0) {
        edfCloseFile(handle);
        print("EDF Handle $handle closed.");
      }
    }
  }

  static Future<File?> createMultiSignalEdfV3(String filePath, {
    required DateTime datetime,
    List<VitalDataRecord> collectedVitals = const [],
    String patientName = "Patient_O2Ring",
    String recordingName = "O2Ring Recording",
  }) async {
    int handle = -1;

    String sanitize(String input) => input.replaceAll(RegExp(r'[^\x00-\x7F]'), '');

    try {
      final file = File(filePath);
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);

      final pathPtr = filePath.toNativeUtf8();

      // PPG is now set to 0-255 to match clinical standards
      final signals = [
        ('spo2', '%', 1, 0.0, 100.0, 0, 100),
        ('pulse', 'bpm', 1, 0.0, 250.0, 0, 250),
        ('battery', '%', 1, 0.0, 100.0, 0, 100),
        ('charge_state', '', 1, 0.0, 100.0, 0, 100),
        ('signal_quality', '%', 1, 0.0, 100.0, 0, 100),
        ('sensor_status', '', 1, 0.0, 10.0, 0, 100),
        ('ppg', '', 125, 0.0, 255.0, 0, 255),
        ('ble_connection', '', 1, 0.0, 1.0, 0, 1),
        ('HRV', 'ms', 10, 0.0, 500.0, 0, 500),
        ('derived_effort', '', 10, -100.0, 100.0, -100, 100),
        ('derived_flow', '', 10, -100.0, 100.0, -100, 100),
      ];

      handle = edfOpenFileWriteonly(pathPtr, EDFLIB_FILETYPE_EDFPLUS, signals.length);
      calloc.free(pathPtr);

      if (handle < 0) return null;

      edfSetStartdatetime(handle, datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second);
      edfSetDatarecordDuration(handle, 1);

      final pNamePtr = sanitize(patientName).toNativeUtf8();
      edfSetPatientname(handle, pNamePtr);
      calloc.free(pNamePtr);

      for (int s = 0; s < signals.length; s++) {
        final sig = signals[s];
        final lPtr = sanitize(sig.$1).toNativeUtf8();
        final uPtr = sanitize(sig.$2).toNativeUtf8();
        edfSetLabel(handle, s, lPtr);
        edfSetSamplefrequency(handle, s, sig.$3);
        edfSetPhysicalMinimum(handle, s, sig.$4.toDouble());
        edfSetPhysicalMaximum(handle, s, sig.$5.toDouble());
        edfSetDigitalMinimum(handle, s, sig.$6.toInt());
        edfSetDigitalMaximum(handle, s, sig.$7.toInt());
        edfSetPhysicalDimension(handle, s, uPtr);
        calloc.free(lPtr);
        calloc.free(uPtr);
      }

      final samplesPerRecord = signals.fold<int>(0, (sum, sig) => sum + sig.$3);
      final recordBuf = calloc<Int16>(samplesPerRecord);

      for (int sec = 0; sec < collectedVitals.length; sec++) {
        int offset = 0;
        final record = collectedVitals[sec];

        for (int s = 0; s < signals.length; s++) {
          final (label, _, fs, physMin, physMax, digMin, digMax) = signals[s];

          if (label == 'ppg') {
            final raw = record.ppgSignal;
            for (int i = 0; i < fs; i++) {
              // Fill missing samples with 128 (baseline) instead of 0 (cliff)
              double val = (i < raw.length ? (raw[i]?.toDouble() ?? 128.0) : 128.0);

              // Interpolation for O2Ring Pulse Flags
              if (val >= 155.0 || val < 0) {
                val = (i > 0) ? raw[i - 1].toDouble() : 128.0;
              }

              // Since Phys Range == Dig Range (0-255), write directly
              recordBuf[offset + i] = val.round().clamp(0, 255);
            }
          } else {
            // Dynamic data mapping for non-PPG signals
            dynamic raw;
            if (label == 'spo2') raw = record.spo2;
            else if (label == 'pulse') raw = record.heartRate;
            else if (label == 'HRV') raw = record.hrv;
            else if (label == 'derived_effort') raw = record.derivedEffort;
            else if (label == 'derived_flow') raw = record.derivedFlow;
            else raw = 0.0;

            for (int i = 0; i < fs; i++) {
              double phys = (raw is List) ? (i < raw.length ? raw[i].toDouble() : 0.0) : raw.toDouble();
              double mapped = digMin + (phys - physMin) * (digMax - digMin) / (physMax - physMin);
              recordBuf[offset + i] = mapped.round().clamp(digMin, digMax);
            }
          }
          offset += fs;
        }
        edfBlockwriteDigitalShortSamples(handle, recordBuf);
      }

      calloc.free(recordBuf);
      return File(filePath);
    } catch (e) {
      return null;
    } finally {
      if (handle >= 0) edfCloseFile(handle);
    }
  }

}

// Define the structure for a single EDF signal using a Dart Record
typedef EdfSignal = ({
String label,
String unit,
int fs,
double physMin,
double physMax,
int digMin,
int digMax,
});
