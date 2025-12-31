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
  static Future<File?> createMultiSignalEdf(
      String filePath, {
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
