import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as Math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'edf_lib.dart';
import 'vital_data_records.dart';

class EDFHelper {
  static Future<File?> createMultiSignalEdf(String filePath) async {
    try {
      final pathPtr = filePath.toNativeUtf8();
      // Define signals per spec
      final signals = [
        // label, unit, fs, physMin, physMax, digMin, digMax
        ('EEG O1-A2', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('EEG O2-A1', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('EOG ROC-A2', 'uV', 200, -300.0, 300.0, 0, 4095),
        ('Snore', 'dBFS', 8000, -100.0, 100.0, 0, 4095),
        ('Flow Patient', 'LPM', 25, -3276.8, 3276.7, -32768, 32767),
        ('Effort THO', 'uV', 10, -100.0, 100.0, 0, 4095),
        ('SpO2', '%', 1, 0.0, 102.3, 0, 1023),
        ('SpO2-2', '%', 1, 0.0, 102.3, 0, 1023),
        ('Body', 'N/A', 1, 0.0, 255.0, 0, 255),
        ('PulseRate', 'bpm', 1, 0.0, 1023.0, 0, 1023),
        ('PulseRate-2', 'bpm', 1, 0.0, 1023.0, 0, 1023),
        ('PPG', 'N/A', 100, -100.0, 100.0, -32768, 32767),
        ('PPG-2', 'N/A', 100, -100.0, 100.0, -32768, 32767),
      ];

      final handle = edfOpenFileWriteonly(
        pathPtr,
        EDFLIB_FILETYPE_EDFPLUS,
        signals.length,
      );
      calloc.free(pathPtr);

      if (handle < 0) {
        print('Failed to open EDF for write: $handle');
        return null;
      }

      // Set recording start time and datarecord duration (1 second)
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
      final patientPtr = 'SleepMD'.toNativeUtf8();
      edfSetPatientname(handle, patientPtr);
      calloc.free(patientPtr);
      final recPtr = 'O2 Ring mock multi-signal'.toNativeUtf8();
      edfSetRecordingAdditional(handle, recPtr);
      calloc.free(recPtr);

      // Set per-signal params
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
        final unitPtr = (unit == 'N/A'
            ? ''.toNativeUtf8()
            : unit.toNativeUtf8());
        edfSetPhysicalDimension(handle, s, unitPtr);
        calloc.free(unitPtr);
      }

      // Duration and write loop: generate 10 seconds
      const seconds = 10;

      // For blockwrite we must interleave per record: n samples of s0, then s1, ...
      // Determine total samples per record (sum of each fs)
      int totalSamplesPerRecord = 0;
      for (final sig in signals) {
        totalSamplesPerRecord += sig.$3; // fs
      }

      final recordBuf = calloc<Int16>(totalSamplesPerRecord);

      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;
        for (int s = 0; s < signals.length; s++) {
          final (label, unit, fs, physMin, physMax, digMin, digMax) =
              signals[s];
          // generate mock waveform per signal
          for (int i = 0; i < fs; i++) {
            double phys;
            switch (label) {
              case 'EEG O1-A2':
              case 'EEG O2-A1':
              case 'EOG ROC-A2':
                phys =
                    50.0 *
                    Math.sin(2 * Math.pi * (i / fs) * 10.0); // microvolt osc
                break;
              case 'Snore':
                phys = (i % 200 < 5) ? 80.0 : 10.0; // spikes
                break;
              case 'Flow Patient':
                phys = 500.0 * Math.sin(2 * Math.pi * (i / fs) * 0.3);
                break;
              case 'Effort THO':
                phys = 50.0 * Math.sin(2 * Math.pi * (i / fs) * 0.3 + 1.0);
                break;
              case 'SpO2':
                phys = 96.0 + ((sec % 5) == 4 ? -1.0 : 0.0);
                break;
              case 'SpO2-2':
                phys = 95.5 + ((sec % 6) == 5 ? -1.0 : 0.0);
                break;
              case 'Body':
                phys = (sec < seconds / 2) ? 96.0 : 128.0; // two positions
                break;
              case 'PulseRate':
                phys = 65.0 + (sec % 10);
                break;
              case 'PulseRate-2':
                phys = 66.0 + (sec % 9);
                break;
              case 'PPG':
                phys = 60.0 * Math.sin(2 * Math.pi * (i / fs) * 1.2);
                break;
              case 'PPG-2':
                phys = 55.0 * Math.sin(2 * Math.pi * (i / fs) * 1.2 + 0.5);
                break;
              default:
                phys = 0.0;
            }
            // map physical to digital
            final mapped =
                (digMin +
                        (phys - physMin) *
                            (digMax - digMin) /
                            (physMax - physMin))
                    .round();
            recordBuf[offset + i] = mapped.clamp(-32768, 32767);
          }
          offset += fs;
        }

        final w = edfBlockwriteDigitalShortSamples(handle, recordBuf);
        if (w != 0) {
          print('edfBlockwriteDigitalShortSamples failed with $w at sec $sec');
        }

        // Optional: write a per-second annotation on first and last record
        if (sec == 0) {
          final desc = 'Recording starts'.toNativeUtf8();
          edfwriteAnnotationUtf8Hr(handle, 0, -1, desc);
          calloc.free(desc);
        }
        if (sec == seconds - 1) {
          final desc = 'Recording ends'.toNativeUtf8();
          edfwriteAnnotationUtf8Hr(handle, seconds * 1000000, -1, desc);
          calloc.free(desc);
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
  static Future<File?> createEdfFromDeviceData(
    String filePath,
    List<VitalDataRecord> records,
  ) async {
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


  static Future<File?> createO2RingEdf(String filePath) async {
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
      print('Creating EDF file at: $pathPtr');

      // Define signals for standard EDF (no annotation channel)
      // Format: (label, unit, fs, physMin, physMax, digMin, digMax)
      final signals = [
        ('spo2', '%', 10, 0.0, 100.0, 0, 100),
        ('pulse', 'bpm', 10, 0.0, 100, 0, 100),
        ('battery', '%', 10, 0.0, 100.0, 0, 100),
        ('charge_state', '', 10, 0.0, 100, 0, 100),
        ('signal_quality', '%', 10, 0.0, 100, 0, 100),
        ('sensor_status', '', 10, 0.0, 100, 0, 100),
        ('heart_rate_varia', 'ms', 10, -100, 100, -100, 100),
        ('ppg', 'mV',125, 0, 255, 0, 255),
        ('derived_effort', 'units', 10, -100, 100, -100, 100),
        ('derived_flow', 'LPM', 10, -100, 100, -100, 100),
      ];

      print('Opening EDF file with ${signals.length} signals...');
      // Try using the simpler edfOpenFileWriteonlyWithParams first
      final handle = edfOpenFileWriteonlyWithParams(
        pathPtr,
        EDFLIB_FILETYPE_EDFPLUS,
        signals.length,
        10,
        100,
        ''.toNativeUtf8(), // phys dimension (will be overridden per signal)
      );
      calloc.free(pathPtr);

      if (handle < 0) {
        print('Failed to open EDF for write: $handle');
        print(
          'Error codes: -1=file already exists, -2=can\'t write to file, -3=file not found, -4=invalid header, -5=invalid file type, -6=invalid number of signals, -7=invalid file name',
        );
        return null;
      }

      print('EDF file opened successfully with handle: $handle');

      // Set recording start time and datarecord duration (1 second)
      final start = DateTime.now();
      final startResult = edfSetStartdatetime(
        handle,
        start.year,
        start.month,
        start.day,
        start.hour,
        start.minute,
        start.second,
      );
      if (startResult != 0) {
        print('Warning: edfSetStartdatetime returned $startResult');
      }

      final durationResult = edfSetDatarecordDuration(handle, 1);
      if (durationResult != 0) {
        print('Warning: edfSetDatarecordDuration returned $durationResult');
      }

      // Set simple metadata for standard EDF
      final patientPtr = 'Patient_O2Ring'.toNativeUtf8();
      final patientResult = edfSetPatientname(handle, patientPtr);
      calloc.free(patientPtr);
      if (patientResult != 0) {
        print('Warning: edfSetPatientname returned $patientResult');
      }

      final recPtr = 'O2Ring Recording'.toNativeUtf8();
      final recResult = edfSetRecordingAdditional(handle, recPtr);
      calloc.free(recPtr);
      if (recResult != 0) {
        print('Warning: edfSetRecordingAdditional returned $recResult');
      }

      print('Setting signal parameters...');
      // Set per-signal parameters
      for (int s = 0; s < signals.length; s++) {
        final (label, unit, fs, physMin, physMax, digMin, digMax) = signals[s];
        final labelPtr = label.toNativeUtf8();
        final labelResult = edfSetLabel(handle, s, labelPtr);
        calloc.free(labelPtr);
        if (labelResult != 0) {
          print(
            'Warning: edfSetLabel for signal $s ($label) returned $labelResult',
          );
        }

        final freqResult = edfSetSamplefrequency(handle, s, fs);
        if (freqResult != 0) {
          print(
            'Warning: edfSetSamplefrequency for signal $s returned $freqResult',
          );
        }

        final physMinResult = edfSetPhysicalMinimum(handle, s, physMin.toDouble());
        if (physMinResult != 0) {
          print(
            'Warning: edfSetPhysicalMinimum for signal $s returned $physMinResult',
          );
        }

        final physMaxResult = edfSetPhysicalMaximum(handle, s, physMax.toDouble());
        if (physMaxResult != 0) {
          print(
            'Warning: edfSetPhysicalMaximum for signal $s returned $physMaxResult',
          );
        }

        final digMinResult = edfSetDigitalMinimum(handle, s, digMin);
        if (digMinResult != 0) {
          print(
            'Warning: edfSetDigitalMinimum for signal $s returned $digMinResult',
          );
        }

        final digMaxResult = edfSetDigitalMaximum(handle, s, digMax);
        if (digMaxResult != 0) {
          print(
            'Warning: edfSetDigitalMaximum for signal $s returned $digMaxResult',
          );
        }

        // final unitPtr = unit.isEmpty ? ''.toNativeUtf8() : unit.toNativeUtf8();
        // final unitResult = edfSetPhysicalDimension(handle, s, unitPtr);
        // calloc.free(unitPtr);
        // if (unitResult != 0) {
        //   print(
        //     'Warning: edfSetPhysicalDimension for signal $s returned $unitResult',
        //   );
        // }
      }

      print('Writing data...');
      // Duration and write loop: generate data
      const seconds = 28800; // Further reduced for testing
      final random = Math.Random();

      // Determine total samples per record (sum of each fs)
      int totalSamplesPerRecord = 0;
      for (final sig in signals) {
        totalSamplesPerRecord += sig.$3; // fs
      }
      print('Total samples per record: $totalSamplesPerRecord');

      final recordBuf = calloc<Int16>(totalSamplesPerRecord);

      for (int sec = 0; sec < seconds; sec++) {
        int offset = 0;
        for (int s = 0; s < signals.length; s++) {
          final (label, unit, fs, physMin, physMax, digMin, digMax) =
              signals[s];

          // Generate mock waveform per signal
          for (int i = 0; i < fs; i++) {
            double phys;
            final t = i / fs;

            switch (label) {
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
                phys =
                    50.0 * Math.sin(2 * Math.pi * t * 1.2) +
                    20 * Math.cos(2 * Math.pi * t * 2.4);
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
                phys = 100.0 - (sec * 1.0 / seconds * 10);
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
              case 'heart_rate_varia':
              default:
                phys = 15.0 + (sec % 5).toDouble() + random.nextDouble() * 2.0;
                break;
            }

            // Map physical to digital
            final mapped =
                (digMin +
                        (phys - physMin) *
                            (digMax - digMin) /
                            (physMax - physMin))
                    .round();
            recordBuf[offset + i] = mapped.clamp(-32768, 32767);
          }
          offset += fs;
        }

        final w = edfBlockwriteDigitalShortSamples(handle, recordBuf);
        if (w != 0) {
          print('edfBlockwriteDigitalShortSamples failed with $w at sec $sec');
          // Continue writing other records even if one fails
        }
      }

      calloc.free(recordBuf);

      print('Closing EDF file...');
      final closeRes = edfCloseFile(handle);
      if (closeRes != 0 && closeRes != 1) {
        print('Warning: closing EDF handle returned $closeRes');
      }

      print('Standard EDF file written successfully at $filePath');
      return File(filePath);
    } catch (e) {
      print('Error creating standard EDF: $e');
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
        label: 'heart_rate_varia',
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
            '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${(now.year % 100).toString().padLeft(2, '0')}',
            8,
          ),
        ),
      );
      // xz cng
      headerBuffer.add(
        ascii.encode(
          _padString(
            '${now.hour.toString().padLeft(2, '0')}.${now.minute.toString().padLeft(2, '0')}.${now.second.toString().padLeft(2, '0')}',
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
              case 'heart_rate_varia':
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
        'Successfully wrote $numberOfDataRecords data records (${totalSamplesWritten} samples).',
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
