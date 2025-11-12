import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as Math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'edf_lib.dart';
import 'vital_data_records.dart';

class EDFHelper {
  // Creates a multi-signal EDF file from O2Ring or mock data
  /// This version is corrected for strict parsers:
  /// 1. Uses standard EDF (not EDF+) to avoid the 'EDF Annotations' channel.
  /// 2. Uses lowercase_with_underscore labels.
  static Future<File?> createMultiSignalEdf(String filePath, {
    List<VitalDataRecord> collectedVitals = const [],
    String patientName = "Patient_O2Ring",
    String recordingName = "O2Ring Recording"
  }) async {
    try {
      final pathPtr = filePath.toNativeUtf8();

      // --- FIX 2: Standardized Channel Labels ---
      // All labels are now lowercase, with spaces/hyphens replaced by underscores.
      final signals = [
        // label, unit, fs, physMin, physMax, digMin, digMax
        ('eeg_o1_a2', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('eeg_o2_a1', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('eog_roc_a2', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('snore', 'dBFS', 8000, -100.0, 100.0, 0, 4095),
        ('flow_patient', 'LPM', 25, -3276.8, 3276.7, -32768, 32767),
        ('effort_tho', 'uV', 10, -100.0, 100.0, 0, 4095),
        ('spo2', '%', 1, 0.0, 102.3, 0, 1023),
        ('spo2_2', '%', 1, 0.0, 102.3, 0, 1023),
        ('body', 'N/A', 1, 0.0, 255.0, 0, 255),
        ('pulse_rate', 'bpm', 1, 0.0, 1023.0, 0, 1023),
        ('pulse_rate_2', 'bpm', 1, 0.0, 1023.0, 0, 1023),
        ('ppg', 'N/A', 100, -100.0, 100.0, 0, 255),
        ('ppg_2', 'N/A', 100, -100.0, 100.0, -32768, 32767),
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
      final start = DateTime.now();
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
        edfSetPhysicalMinimum(handle, s, physMin);
        edfSetPhysicalMaximum(handle, s, physMax);
        edfSetDigitalMinimum(handle, s, digMin);
        edfSetDigitalMaximum(handle, s, digMax);

        final unitPtr = (unit == 'N/A' ? ''.toNativeUtf8() : unit
            .toNativeUtf8());
        edfSetPhysicalDimension(handle, s, unitPtr);
        calloc.free(unitPtr);
      }

      // Determine number of seconds
      final seconds = collectedVitals.isNotEmpty ? collectedVitals.length : 10;
      final random = Math.Random();

      // Determine total samples per record
      final totalSamplesPerRecord = signals.fold<int>(
          0, (sum, sig) => sum + sig.$3);
      final recordBuf = calloc<Int16>(totalSamplesPerRecord);

      // Start writing each second
      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;
        final record = collectedVitals.isNotEmpty ? collectedVitals[sec] : null;

        for (int s = 0; s < signals.length; s++) {
          final (label, unit, fs, physMin, physMax, digMin, digMax) = signals[s];

          for (int i = 0; i < fs; i++) {
            double phys;

            if (record != null) {
              // Cast any dynamic lists to List<double> to avoid type issues
              final ppgSignal = record.ppgSignal.cast<double>();
              final ecgSignal = record.ecgSignal.cast<double>();

              // --- FIX 3: Updated Data Mapping ---
              // The keys in this map MUST match the new labels from the 'signals' array.
              final recordMap = {
                'spo2': record.spo2.toDouble(),
                'pulse_rate': record.heartRate.toDouble(),
                'ppg': ppgSignal,
                'ppg_2': ppgSignal,
                // if you have multiple channels
                // NOTE: You are not mapping your other 'VitalDataRecord' fields
                // (e.g., eeg, eog) to the corresponding EDF channels.
                // You will need to add them to this map if you want real data there.
              };

              final value = recordMap[label];
              if (value is List<double>) {
                phys = i < value.length ? value[i] : 0.0;
              } else if (value is num) {
                phys = value.toDouble();
              } else {
                phys = 0.0; // Default for unmapped channels
              }
            } else {
              // Mock waveform generation
              final t = i / fs;
              // --- FIX 3: Updated Mock Data Mapping ---
              // The 'case' statements MUST match the new labels.
              switch (label) {
                case 'eeg_o1_a2':
                case 'eeg_o2_a1':
                case 'eog_roc_a2':
                  phys = 50.0 * Math.sin(2 * Math.pi * t * 10.0);
                  break;
                case 'snore':
                  phys = (i % 200 < 5) ? 80.0 : 10.0;
                  break;
                case 'flow_patient':
                  phys = 500.0 * Math.sin(2 * Math.pi * t * 0.3);
                  break;
                case 'effort_tho':
                  phys = 50.0 * Math.sin(2 * Math.pi * t * 0.3 + 1.0);
                  break;
                case 'spo2':
                  phys = 96.0 + ((sec % 5) == 4 ? -1.0 : 0.0);
                  break;
                case 'spo2_2':
                  phys = 95.5 + ((sec % 6) == 5 ? -1.0 : 0.0);
                  break;
                case 'body':
                  phys = (sec < seconds / 2) ? 96.0 : 128.0;
                  break;
                case 'pulse_rate':
                  phys = 65.0 + (sec % 10);
                  break;
                case 'pulse_rate_2':
                  phys = 66.0 + (sec % 9);
                  break;
                case 'ppg':
                  phys = 60.0 * Math.sin(2 * Math.pi * t * 1.2);
                  break;
                case 'ppg_2':
                  phys = 55.0 * Math.sin(2 * Math.pi * t * 1.2 + 0.5);
                  break;
                default:
                  phys = 0.0;
              }
            }

            // Map physical to digital
            final mapped = (digMin +
                (phys - physMin) * (digMax - digMin) / (physMax - physMin))
                .round();
            // Clamp to the full 16-bit range, as digMin/digMax can vary
            recordBuf[offset + i] = mapped.clamp(-32768, 32767);
          }

          offset += fs;
        }

        // Write this second
        final w = edfBlockwriteDigitalShortSamples(handle, recordBuf);
        if (w != 0) {
          print('edfBlockwriteDigitalShortSamples failed with $w at sec $sec');
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

  /// Creates an EDF file using data from a list of VitalDataRecords.
  static Future<File?> createEdfFromDeviceData(String filePath,
      List<VitalDataRecord> records,) async {
    // if (records.isEmpty) {
    //   print('No data records provided.');
    //   return null;
    // }

    // Determine the duration of the recording in seconds.
    final int seconds = records.length;

    // Determine sample frequencies dynamically based on the available data.
    int ppgFs = 0;
    int ecgFs = 0;
    for (final r in records) {
      if (r.ppgSignal.isNotEmpty) {
        ppgFs = Math.max(ppgFs, r.ppgSignal.length);
      }
      if (r.ecgSignal.isNotEmpty) {
        ecgFs = Math.max(ecgFs, r.ecgSignal.length);
      }
    }
    // Fallback to default values if no data is present.
    if (ppgFs <= 0) ppgFs = 100;
    if (ecgFs <= 0) ecgFs = 250;

    // Define the signal parameters as per the EDF specification.
    final List<(String, String, int, double, double, int, int)> signals = [];
    final List<int> signalFs = [];

    // SpO2 Signal (if available)
    if (records.any((r) => r.spo2 >= 0)) {
      signals.add(('SpO2', '%', 1, 0.0, 102.3, 0, 1023));
      signalFs.add(1);
    }
    // Pulse Rate Signal (if available)
    if (records.any((r) => r.heartRate >= 0)) {
      signals.add(('PulseRate', 'bpm', 1, 0.0, 1023.0, 0, 1023));
      signalFs.add(1);
    }
    // PPG Waveform Signal (if available)
    if (ppgFs > 0) {
      signals.add(('PPG', 'mV', ppgFs, -100.0, 100.0, -32768, 32767));
      signalFs.add(ppgFs);
    }
    // ECG Waveform Signal (if available)
    if (ecgFs > 0) {
      signals.add(('ECG', 'uV', ecgFs, -5000.0, 5000.0, -32768, 32767));
      signalFs.add(ecgFs);
    }

    final int numSignals = signals.length;
    if (numSignals == 0) {
      print('No valid signals to write.');
      return null;
    }

    // Calculate the total number of samples per one-second data record.
    final int totalSamplesPerRecord = signalFs.reduce((a, b) => a + b);

    // Allocate a buffer on the C heap to hold the digital samples for one record.
    final recordBuf = calloc<Int16>(totalSamplesPerRecord);
    final pathPtr = filePath.toNativeUtf8();

    try {
      // Open the EDF file for writing with per-signal parameters.
      final hdl = edfOpenFileWriteonly(
        pathPtr,
        EDFLIB_FILETYPE_EDFPLUS,
        numSignals,
      );
      if (hdl < 0) {
        throw 'Error creating EDF file, handle is $hdl';
      }

      // Set the start date and time of the recording.
      final now = DateTime.now();
      edfSetStartdatetime(
        hdl,
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
      );

      // Set the duration of a data record.
      edfSetDatarecordDuration(hdl, 1);

      // Set parameters for each signal.
      for (int i = 0; i < numSignals; i++) {
        final s = signals[i];
        final labelPtr = s.$1.toNativeUtf8();
        final physDimPtr = s.$2.toNativeUtf8();
        final fs = s.$3;
        final physMin = s.$4;
        final physMax = s.$5;
        final digMin = s.$6;
        final digMax = s.$7;

        edfSetLabel(hdl, i, labelPtr);
        edfSetPhysicalDimension(hdl, i, physDimPtr);
        edfSetSamplefrequency(hdl, i, fs);
        edfSetPhysicalMinimum(hdl, i, physMin);
        edfSetPhysicalMaximum(hdl, i, physMax);
        edfSetDigitalMinimum(hdl, i, digMin);
        edfSetDigitalMaximum(hdl, i, digMax);

        calloc.free(labelPtr);
        calloc.free(physDimPtr);
      }

      // Write one datarecord for each second.
      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;
        final VitalDataRecord rec = records[sec];

        for (final s in signals) {
          final label = s.$1;
          final fs = s.$3;
          final physMin = s.$4;
          final physMax = s.$5;
          final digMin = s.$6;
          final digMax = s.$7;

          // Apply the physical-to-digital mapping.
          if (label == 'SpO2') {
            final phys = rec.spo2 >= 0 ? rec.spo2.toDouble() : 0.0;
            final mapped =
            (digMin +
                (phys - physMin) *
                    (digMax - digMin) /
                    (physMax - physMin))
                .round();
            recordBuf[offset] = mapped.clamp(digMin, digMax);
            offset += fs;
          } else if (label == 'PulseRate') {
            final phys = rec.heartRate >= 0 ? rec.heartRate.toDouble() : 0.0;
            final mapped =
            (digMin +
                (phys - physMin) *
                    (digMax - digMin) /
                    (physMax - physMin))
                .round();
            recordBuf[offset] = mapped.clamp(digMin, digMax);
            offset += fs;
          } else if (label == 'PPG') {
            final List<double> ppg = rec.ppgSignal;
            final int n = Math.min(fs, ppg.length);
            for (int i = 0; i < fs; i++) {
              double phys = i < n ? ppg[i] : 0.0;
              final mapped =
              (digMin +
                  (phys - physMin) *
                      (digMax - digMin) /
                      (physMax - physMin))
                  .round();
              recordBuf[offset + i] = mapped.clamp(digMin, digMax);
            }
            offset += fs;
          } else if (label == 'ECG') {
            final List<double> ecg = rec.ecgSignal;
            final int n = Math.min(fs, ecg.length);
            for (int i = 0; i < fs; i++) {
              double phys = i < n ? ecg[i] : 0.0;
              final mapped =
              (digMin +
                  (phys - physMin) *
                      (digMax - digMin) /
                      (physMax - physMin))
                  .round();
              recordBuf[offset + i] = mapped.clamp(digMin, digMax);
            }
            offset += fs;
          }
        }
        // Write the complete data record to the file.
        edfBlockwriteDigitalShortSamples(hdl, recordBuf);
      }

      // Close the file and free allocated resources.
      edfCloseFile(hdl);
      calloc.free(pathPtr);
      calloc.free(recordBuf);

      return File(filePath);
    } catch (e) {
      print('Error creating EDF file: $e');
      calloc.free(pathPtr);
      calloc.free(recordBuf);
      return null;
    }
  }


  /// Creates an EDF file from O2Ring data.
  /// Uses collectedVitals if provided, otherwise generates mock data.
  static Future<File?> createO2RingEdf(String filePath, {
    List<VitalDataRecord> collectedVitals = const [],
    String patientName = "Patient_O2Ring",
    String recordingName = "O2Ring Recording"
  }) async {
    try {
      // Ensure directory exists
      final file = File(filePath);
      final directory = file.parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        print('Created directory: ${directory.path}');
      }

      print('Creating EDF file at: $filePath');

      final pathPtr = filePath.toNativeUtf8();

      // Define signals: (label, unit, fs, physMin, physMax, digMin, digMax)
      // All labels are now lowercase/underscore to match the example file.
      final signals = [
        ('spo2', '%', 1, 0.0, 100.0, 0, 100),
        ('pulse', 'bpm', 1, 0.0, 250.0, 0, 250),
        ('battery', '%', 10, 0.0, 100.0, 0, 100),
        ('charge_state', '', 10, 0.0, 100, 0, 100),
        ('signal_quality', '%', 10, 0.0, 100, 0, 100),
        ('sensor_status', '', 10, 0.0, 100, 0, 100),
        // Mapped HRV and Derived Effort to the example's combined label
        ('heart_rate_variaderived_effort', '', 1, 0.0, 255.0, 0, 255),
        // PPG uses standard 16-bit digital range (Crucial fix for parser)
        ('ppg', 'mV', 100, -100.0, 100.0, 0, 255),
        ('derived_flow', '', 10, 0, 255, 0, 255),
        // Re-added the 10th signal with the correct lowercase label
        ('derived_effort', '', 10, 0, 255, 0, 255),
      ];

      // Open EDF file
      // *** FINAL CRITICAL FIX: Changed from EDFPLUS to standard EDF ***
      final handle = edfOpenFileWriteonly(
        pathPtr,
        EDFLIB_FILETYPE_EDFPLUS,
        // USE STANDARD EDF CONSTANT HERE (e.g., 1 or 0)
        signals.length,
      );
      calloc.free(pathPtr);

      if (handle < 0) {
        print('Failed to open EDF for write: $handle');
        return null;
      }

      // Set start time
      final start = DateTime.now();
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

      // Set patient metadata
      final patientPtr = patientName.toNativeUtf8();
      edfSetPatientname(handle, patientPtr);
      calloc.free(patientPtr);

      final recPtr = recordingName.toNativeUtf8();
      edfSetRecordingAdditional(handle, recPtr);
      calloc.free(recPtr);

      // Set signal parameters
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
        // Provide physical dimension/unit for better viewer compatibility
        final unitPtr = unit.toNativeUtf8();
        edfSetPhysicalDimension(handle, s, unitPtr);
        calloc.free(unitPtr);
      }

      print('Writing data...');

      // Compute total samples per data record
      int totalSamplesPerRecord = signals.fold(0, (sum, sig) => sum + sig.$3);
      final recordBuf = calloc<Int16>(totalSamplesPerRecord);

      final seconds = collectedVitals.length; // 8 hours for mock data
      final random = Math.Random();

      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;
        VitalDataRecord? record =
        collectedVitals.isNotEmpty ? collectedVitals[sec] : null;

        for (int s = 0; s < signals.length; s++) {
          final (label, unit, fs, physMin, physMax, digMin, digMax) = signals[s];

          for (int i = 0; i < fs; i++) {
            double phys = 0;

            if (record != null) {
              // Map from collectedVitals using NEW lowercase/underscore labels
              final recordMap = {
                'spo2': record.spo2.toDouble(),
                'pulse': record.heartRate.toDouble(),
                'ppg': record.ppgSignal,
                'battery': record.battery.toDouble(),
                'charge_state': record.chargeState.toDouble(),
                'signal_quality': record.signalQuality.toDouble(),
                'sensor_status': record.sensorStatus.toDouble(),
                'derived_effort': record.derivedEffort,
                'derived_flow': record.derivedFlow,
                'heart_rate_variaderived_effort': record.hrv,
              };

              final value = recordMap[label];
              if (value is List<double>) {
                // Ensure we don't index beyond the PPG array length
                phys = i < value.length ? value[i] : 0.0;
              } else if (value is num) {
                phys = value.toDouble();
              } else {
                phys = 0.0;
              }
            }

            // Map physical to digital
            final mapped = (digMin +
                (phys - physMin) * (digMax - digMin) / (physMax - physMin))
                .round();
            // Clamp to the signal's specified digital range
            recordBuf[offset + i] = mapped.clamp(digMin, digMax);
          }

          offset += fs;
        }

        final w = edfBlockwriteDigitalShortSamples(handle, recordBuf);
        if (w != 0) {
          print('edfBlockwriteDigitalShortSamples failed with $w at sec $sec');
        }
      }

      calloc.free(recordBuf);

      print('Closing EDF file...');
      final closeRes = edfCloseFile(handle);
      if (closeRes != 0 && closeRes != 1) {
        print('Warning: closing EDF handle returned $closeRes');
      }

      print('EDF file written successfully at $filePath');
      return File(filePath);
    } catch (e) {
      print('Error creating EDF: $e');
      return null;
    }
  }

  static Future<File?> createEdfFileDart(String filePath) async {
    // The same signal definitions as in the original FFI code
    // The same signal definitions as in the original FFI code
    final signals = <EdfSignal>[
      (
      label: 'spo2',
      unit: '%',
      fs: 1,
      physMin: 0.0,
      physMax: 100.0,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'pulse',
      unit: 'bpm',
      fs: 1,
      physMin: 0.0,
      physMax: 100.0,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'battery',
      unit: '%',
      fs: 1,
      physMin: 0.0,
      physMax: 100.0,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'charge_state',
      unit: '',
      fs: 1,
      physMin: 0,
      physMax: 100,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'signal_quality',
      unit: '%',
      fs: 1,
      physMin: 0.0,
      physMax: 100.0,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'sensor_status',
      unit: '',
      fs: 1,
      physMin: 0,
      physMax: 100,
      digMin: 0,
      digMax: 100,
      ),
      (
      label: 'heart_rate_variaderived_effort',
      unit: 'ms',
      fs: 1,
      physMin: -100,
      physMax: 100,
      digMin: -100,
      digMax: 100,
      ),
      (
      label: 'ppg',
      unit: 'mV',
      fs: 125,
      physMin: 0,
      physMax: 255,
      digMin: 0,
      digMax: 255,
      ),
      (
      label: 'derived_effort',
      unit: 'units',
      fs: 10,
      physMin: -100.0,
      physMax: 100.0,
      digMin: -100,
      digMax: 100,
      ),
      (
      label: 'derived_flow',
      unit: 'LPM',
      fs: 10,
      physMin: -100,
      physMax: 100,
      digMin: -100,
      digMax: 100,
      ),
    ];

    const seconds = 30101;
    const dataRecordDuration = 10.0; // Duration of one data record in seconds
    final numberOfDataRecords = (seconds / dataRecordDuration).ceil();
    final numberOfSignals = signals.length;
    final headerSize = 256 + numberOfSignals * 256; // Fixed size for EDF header

    final now = DateTime.now();
    final random = Math.Random();

    // Initialize file sink
    final file = File(filePath);
    final sink = file.openSync(mode: FileMode.write);

    try {
      // --- 1. Write the Fixed-Length ASCII Header Record ---
      final headerBuffer = BytesBuilder();

      // 1.1. General Header (256 bytes)
      headerBuffer.add(ascii.encode(_padString('0', 8))); // Version (8 bytes)
      headerBuffer.add(
        ascii.encode(_padString('Patient_O2Ring', 80)),
      ); // Patient ID (80 bytes)
      headerBuffer.add(
        ascii.encode(_padString('O2Ring Recording', 80)),
      ); // Recording ID (80 bytes)

      // Date and Time (8 bytes each)
      headerBuffer.add(
        ascii.encode(
          _padString(
            '${now.day.toString().padLeft(2, '0')}.${now.month
                .toString()
                .padLeft(2, '0')}.${(now.year % 100).toString().padLeft(
                2, '0')}',
            8,
          ),
        ),
      );
      // xz cng
      headerBuffer.add(
        ascii.encode(
          _padString(
            '${now.hour.toString().padLeft(2, '0')}.${now.minute
                .toString()
                .padLeft(2, '0')}.${now.second.toString().padLeft(2, '0')}',
            8,
          ),
        ),
      );

      // Header Length (256 + n * 256) (8 bytes)
      headerBuffer.add(ascii.encode(_padString(headerSize.toString(), 8)));

      // Reserved (44 bytes) - Changed to empty string for standard EDF
      headerBuffer.add(ascii.encode(_padString('', 44)));

      // Number of Data Records (8 bytes)
      headerBuffer.add(
        ascii.encode(_padString(numberOfDataRecords.toString(), 8)),
      );
      // Data Record Duration in seconds (8 bytes)
      headerBuffer.add(
        ascii.encode(_padString(dataRecordDuration.toStringAsFixed(0), 8)),
      );

      // Number of Signals (4 bytes)
      headerBuffer.add(ascii.encode(_padString(numberOfSignals.toString(), 4)));

      // 1.2. Signal-Specific Header (N_signals * 256 bytes)
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString(signal.label, 16)),
        ); // Label (16 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString('', 80)),
        ); // Transducer type (80 bytes)
      }
      // for (final signal in signals) {
      //   headerBuffer.add(
      //     ascii.encode(_padString(signal.unit, 8)),
      //   ); // Physical dimension (8 bytes)
      // }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString(signal.physMin.toStringAsFixed(0), 8)),
        ); // Physical Min (8 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString(signal.physMax.toStringAsFixed(0), 8)),
        ); // Physical Max (8 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString(signal.digMin.toStringAsFixed(0), 8)),
        ); // Digital Min (8 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString(signal.digMax.toStringAsFixed(0), 8)),
        ); // Digital Max (8 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString('', 80)),
        ); // Preprocessing info (80 bytes)
      }
      for (final signal in signals) {
        // Number of samples per data record (fs * dataRecordDuration)
        headerBuffer.add(
          ascii.encode(_padString(signal.fs.toString(), 8)),
        ); // Samples/Record (8 bytes)
      }
      for (final signal in signals) {
        headerBuffer.add(
          ascii.encode(_padString('', 32)),
        ); // Reserved (32 bytes)
      }

      // Write Header
      sink.writeFromSync(headerBuffer.toBytes());
      print('EDF Header written (${headerBuffer.length} bytes).');

      // --- 2. Write Data Records ---
      final dataRecordBuffer = ByteData(
        2,
      ); // Buffer for 16-bit short samples (2 bytes)
      int totalSamplesWritten = 0;

      // Loop over the total number of data records
      for (int sec = 0; sec < numberOfDataRecords; sec++) {
        // Loop through all signals, writing the samples for each signal sequentially
        for (final signal in signals) {
          // Generate and write mock waveform for this signal for one data record duration (1 second)
          for (int i = 0; i < signal.fs; i++) {
            double phys;
            final t =
                i / signal.fs; // Time normalized within the 1-second interval

            // Your original mock data generation logic, adjusted for Dart
            switch (signal.label) {
              case 'spo2':
                phys =
                    96.0 +
                        (sec % 5 == 4 ? -2.0 : 0.0) +
                        (random.nextDouble() * 0.5);
                break;
              case 'pulse':
                phys =
                    65.0 + (sec % 10).toDouble() + (random.nextDouble() * 0.5);
                break;
              case 'ppg':
              // Simulated oscillatory waveform at ~1.2Hz and its harmonic
                phys =
                    500.0 * Math.sin(2 * Math.pi * t * 1.2) +
                        200.0 * Math.cos(2 * Math.pi * t * 2.4) +
                        random.nextDouble() * 10.0;
                break;
              case 'derived_effort':
                phys =
                    50.0 * Math.sin(2 * Math.pi * t * 0.3) +
                        random.nextDouble() * 5.0;
                break;
              case 'derived_flow':
                phys =
                    1500.0 * Math.sin(2 * Math.pi * t * 0.3) +
                        random.nextDouble() * 10.0;
                break;
              case 'battery':
              // Simulate battery decrease over the total duration
                phys =
                    signal.physMax - (sec * 1.0 / numberOfDataRecords) * 10.0;
                break;
              case 'charge_state':
                phys = 0.0;
                break;
              case 'signal_quality':
                phys = 95.0 - (random.nextDouble() * 5.0);
                break;
              case 'sensor_status':
                phys = 0.0;
                break;
              case 'heart_rate_variaderived_effort':
              default:
                phys = 15.0 + (sec % 5).toDouble() + random.nextDouble() * 2.0;
                break;
            }

            // Convert physical value to digital 16-bit integer
            final digitalValue = _scaleToDigital(phys, signal);

            // Write the 16-bit signed integer (short) in little-endian format
            // EDF standard mandates 16-bit little-endian storage for samples
            dataRecordBuffer.setInt16(0, digitalValue, Endian.little);

            sink.writeFromSync(dataRecordBuffer.buffer.asUint8List());
            totalSamplesWritten++;
          }
        }
      }

      print(
        'Successfully wrote $numberOfDataRecords data records ($totalSamplesWritten samples).',
      );

      // Close the file handle
      await sink.close();
      return file;
    } catch (e) {
      print('Error creating pure Dart EDF file: $e');
      // Ensure the sink is closed on error
      await sink.close();
      // Delete incomplete file
      if (file.existsSync()) file.deleteSync();
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

/// Ensures a string is padded on the right with spaces to meet the exact required length
/// for the EDF header specification.
String _padString(String s, int length) {
  // Truncate if too long, then pad.
  return s.substring(0, Math.min(s.length, length)).padRight(length);
}

/// Converts a physical floating-point value to a digital 16-bit integer,
/// scaled according to the signal's defined range.
int _scaleToDigital(double physValue, EdfSignal signal) {
  final physRange = signal.physMax - signal.physMin;
  final digRange = signal.digMax - signal.digMin;

  if (physRange == 0 || digRange == 0) {
    // Avoid division by zero, return mid-point or min if ranges are zero.
    return signal.digMin;
  }

  // Scaling formula: Digital = DigitalMin + (Phys - PhysMin) * (DigitalRange / PhysRange)
  final mappedValue =
      signal.digMin + (physValue - signal.physMin) * (digRange / physRange);

  // Round and clamp to ensure it's a valid 16-bit integer
  return mappedValue.round().clamp(signal.digMin, signal.digMax);
}
