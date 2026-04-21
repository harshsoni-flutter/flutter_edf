import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'edf_lib.dart';
import 'vital_data_records.dart';

/// A helper class to manage the creation of EDF (European Data Format) files.
///
/// Signal definitions match the working Biorhythms Mobile EDF format that
/// EnsoData successfully processes. Verified against a known-good 28,996-record
/// EDF file ("Biorhythms Mobile (2).edf").
class EDFHelper {

  /// Primary entry point to generate an EDF+ file from collected vital data.
  static Future<File?> createEdfFile(String filePath, {
    required DateTime datetime,
    List<VitalDataRecord> collectedVitals = const [],
    String recordingName = "O2Ring Recording",
    String patientName = "Patient",
  }) async {
    int handle = -1;
    Pointer<Int16>? recordBuf;

    try {
      // 1. Prepare Environment
      _ensureDirectoryExists(filePath);
      final signals = _getSignalDefinitions();

      // 2. Open File
      final pathPtr = filePath.toNativeUtf8();
      handle = edfOpenFileWriteonly(
          pathPtr, EDFLIB_FILETYPE_EDFPLUS, signals.length);
      calloc.free(pathPtr);

      if (handle < 0) throw Exception(
          "Failed to open EDF file. Error code: $handle");

      // 3. Setup Global Header
      _setGlobalHeader(handle, datetime, patientName, recordingName);

      // 4. Setup Signal Headers
      for (int i = 0; i < signals.length; i++) {
        _setSignalHeader(handle, i, signals[i]);
      }

      // 5. Write Data Records
      final totalSamplesPerSecond = signals.fold<int>(
          0, (sum, sig) => sum + sig.fs);
      recordBuf = calloc<Int16>(totalSamplesPerSecond);

      for (var record in collectedVitals) {
        _fillBufferForSecond(recordBuf, record, signals);
        edfBlockwriteDigitalShortSamples(handle, recordBuf);
      }

      print('EDF successfully written to $filePath');
      return File(filePath);
    } catch (e) {
      print('EDF Generation Error: $e');
      return null;
    } finally {
      // 6. Cleanup Resources
      if (recordBuf != null) calloc.free(recordBuf);
      if (handle >= 0) {
        edfCloseFile(handle);
      }
    }
  }

  /// Defines the clinical signal mapping for the O2Ring device.
  ///
  /// These ranges are taken EXACTLY from the working "Biorhythms Mobile (2).edf"
  /// that EnsoData processes without errors. All channels use identity mapping
  /// (physical value == digital value) so the raw device values are stored
  /// directly.
  static List<EdfSignal> _getSignalDefinitions() {
    return [
      (label: 'spo2',           unit: '%',  fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'pulse',          unit: 'bpm',fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'battery',        unit: '%',  fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'charge_state',   unit: '',   fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'signal_quality', unit: '%',  fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'sensor_status',  unit: '',   fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'ppg',            unit: '',   fs: 125, physMin: 0.0,    physMax: 255.0,  digMin: 0,    digMax: 255),
      (label: 'ble_connection', unit: '',   fs: 1,   physMin: 0.0,    physMax: 100.0,  digMin: 0,    digMax: 100),
      (label: 'HRV',            unit: 'ms', fs: 10,  physMin: -100.0, physMax: 100.0,  digMin: -100, digMax: 100),
      (label: 'derived_effort', unit: '',   fs: 10,  physMin: -100.0, physMax: 100.0,  digMin: -32768, digMax: 32767),
      (label: 'derived_flow',   unit: '',   fs: 10,  physMin: -100.0, physMax: 100.0,  digMin: -100, digMax: 100),
    ];
  }

  /// Sets the general file metadata.
  static void _setGlobalHeader(int handle, DateTime dt, String patient,
      String recording) {
    edfSetStartdatetime(
        handle,
        dt.year,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
        dt.second);
    edfSetDatarecordDuration(handle, 1);

    final pPtr = _sanitize(patient).toNativeUtf8();
    final rPtr = _sanitize(recording).toNativeUtf8();

    edfSetPatientname(handle, pPtr);
    edfSetRecordingAdditional(handle, rPtr);

    calloc.free(pPtr);
    calloc.free(rPtr);
  }

  /// Configures individual signal headers.
  static void _setSignalHeader(int handle, int index, EdfSignal sig) {
    final lPtr = _sanitize(sig.label).toNativeUtf8();
    final uPtr = _sanitize(sig.unit).toNativeUtf8();

    edfSetLabel(handle, index, lPtr);
    edfSetPhysicalDimension(handle, index, uPtr);
    edfSetSamplefrequency(handle, index, sig.fs);
    edfSetPhysicalMinimum(handle, index, sig.physMin);
    edfSetPhysicalMaximum(handle, index, sig.physMax);
    edfSetDigitalMinimum(handle, index, sig.digMin);
    edfSetDigitalMaximum(handle, index, sig.digMax);

    calloc.free(lPtr);
    calloc.free(uPtr);
  }

  /// Processes one second of data and populates the C-buffer.
  ///
  /// The O2Ring firmware embeds heartbeat markers as single-sample upward
  /// spikes with value 0x9C (156) in the PPG waveform stream. The
  /// [_resamplePpgWithDrops] method detects these markers, resamples the
  /// clean waveform, and re-inserts them as single-sample drops to zero
  /// matching the Biorhythms Mobile reference EDF format.
  static void _fillBufferForSecond(Pointer<Int16> buffer,
      VitalDataRecord record, List<EdfSignal> signals) {
    int offset = 0;

    for (var sig in signals) {
      List<double> values = _extractRawValues(record, sig.label, sig.fs);

      if (sig.label == 'ppg') {
        // Ensure all PPG values are treated as unsigned bytes (0-255).
        // Native layers may send signed bytes (-128 to 127) for values > 127.
        values = values.map((v) {
          int raw = v.toInt();
          if (raw < 0) raw = raw + 256;
          return raw.toDouble().clamp(0.0, 255.0);
        }).toList();

        // Resample PPG with heartbeat marker handling.
        // The O2Ring firmware embeds heartbeat timing as single-sample
        // upward spikes (value 0x9C/156) in the raw PPG stream.
        // This converts them into clean 1-sample drops to zero in the
        // 125 Hz EDF output, matching the Biorhythms Mobile reference.
        // Strategy: detect markers → interpolate out → resample → re-insert as drops.
        if (values.isEmpty) {
          values = List.filled(sig.fs, 128.0);
        } else if (values.length != sig.fs) {
          values = _resamplePpgWithDrops(values, sig.fs);
        }
      } else if (values.length == 1 && sig.fs > 1) {
        // For multi-Hz channels with a single value (HRV, derived_effort,
        // derived_flow): repeat the value so the channel isn't mostly zeros.
        values = List.filled(sig.fs, values[0]);
      }

      for (int i = 0; i < sig.fs; i++) {
        // Use last known value as fallback instead of 0.0
        final double physValue = (i < values.length)
            ? values[i]
            : (values.isNotEmpty ? values.last : 0.0);

        // Linear Mapping: Physical -> Digital
        final double scaled = sig.digMin +
            (physValue - sig.physMin) * (sig.digMax - sig.digMin) /
                (sig.physMax - sig.physMin);

        buffer[offset + i] = scaled.round().clamp(sig.digMin, sig.digMax);
      }
      offset += sig.fs;
    }
  }

  /// Resamples PPG waveform from ~25 Hz to [targetSize] (125 Hz) while
  /// converting heartbeat markers into clean single-sample drops to zero.
  ///
  /// The O2Ring firmware embeds heartbeat timing by replacing one PPG sample
  /// per beat with the value 0x9C (156). These appear as single-sample
  /// **upward spikes** in the raw waveform. The Biorhythms Mobile reference
  /// EDF converts these into single-sample **drops to zero**.
  ///
  /// This method:
  ///   1. Detects heartbeat markers (upward spikes significantly above
  ///      neighbors, OR downward drops significantly below neighbors)
  ///   2. Replaces markers with interpolated values → smooth waveform
  ///   3. Resamples the clean waveform to [targetSize] via linear interp
  ///   4. Re-inserts single-sample drops to 0 at the mapped positions
  ///
  /// The result matches the Biorhythms Mobile reference: smooth waveform
  /// with thin, single-sample heartbeat drops to zero.
  static List<double> _resamplePpgWithDrops(
      List<double> input, int targetSize) {
    if (input.isEmpty) return List.filled(targetSize, 0.0);
    if (input.length == 1) return List.filled(targetSize, input[0]);
    final int n = input.length;

    // --- Step 1: Detect heartbeat marker indices ---
    // Markers are single-sample anomalies: either upward spikes (0x9C = 156
    // from the O2Ring firmware) or downward drops (near 0).
    // Detection: the sample differs from its immediate neighbors by more
    // than 25 units AND the neighbors are close to each other (< 20 apart).
    final Set<int> markerIndices = {};
    for (int i = 1; i < n - 1; i++) {
      final double left = input[i - 1];
      final double right = input[i + 1];
      final double val = input[i];
      final double neighborAvg = (left + right) / 2.0;
      final double diffFromNeighbors = (val - neighborAvg).abs();
      final double neighborSpread = (left - right).abs();

      // Single-sample spike/drop: large jump from neighbors, but
      // neighbors themselves are consistent (not part of a slope).
      if (diffFromNeighbors > 25.0 && neighborSpread < 20.0) {
        markerIndices.add(i);
      }
    }

    // Also check first and last samples against their neighbor
    if (n > 2) {
      // First sample
      final double neighborAvg0 = (input[1] + input[2]) / 2.0;
      if ((input[0] - neighborAvg0).abs() > 30.0) {
        markerIndices.add(0);
      }
      // Last sample
      final double neighborAvgN = (input[n - 2] + input[n - 3]) / 2.0;
      if ((input[n - 1] - neighborAvgN).abs() > 30.0) {
        markerIndices.add(n - 1);
      }
    }

    // --- Step 2: Create a clean version with markers interpolated out ---
    final clean = List<double>.from(input);
    for (final idx in markerIndices) {
      double? leftVal, rightVal;
      for (int l = idx - 1; l >= 0 && l >= idx - 5; l--) {
        if (!markerIndices.contains(l)) {
          leftVal = clean[l];
          break;
        }
      }
      for (int r = idx + 1; r < n && r <= idx + 5; r++) {
        if (!markerIndices.contains(r)) {
          rightVal = clean[r];
          break;
        }
      }
      if (leftVal != null && rightVal != null) {
        clean[idx] = (leftVal + rightVal) / 2.0;
      } else {
        clean[idx] = leftVal ?? rightVal ?? clean[idx];
      }
    }

    // --- Step 3: Resample the clean waveform ---
    final output = _resampleLinear(clean, targetSize);

    // --- Step 4: Re-insert single-sample drops to 0 at mapped positions ---
    // This converts O2Ring upward spike markers into the Biorhythms-style
    // downward drops to zero that EDF viewers expect.
    if (markerIndices.isNotEmpty && n > 1) {
      final double ratio = (targetSize - 1) / (n - 1);
      for (final srcIdx in markerIndices) {
        final int dstIdx = (srcIdx * ratio).round().clamp(0, targetSize - 1);
        output[dstIdx] = 0.0;
      }
    }

    return output;
  }

  /// Resamples a signal to exactly [targetSize] samples using linear
  /// interpolation. Handles up-sampling (e.g. 25 -> 125) and down-sampling.
  static List<double> _resampleLinear(List<double> input, int targetSize) {
    if (input.length == targetSize) return input;
    if (input.isEmpty) return List.filled(targetSize, 0.0);
    if (input.length == 1) return List.filled(targetSize, input[0]);

    final output = List<double>.filled(targetSize, 0.0);
    final double step = (input.length - 1) / (targetSize - 1);

    for (int i = 0; i < targetSize; i++) {
      final double index = i * step;
      final int lower = index.floor();
      final int upper = index.ceil().clamp(0, input.length - 1);
      final double fraction = index - lower;
      output[i] = input[lower] + (input[upper] - input[lower]) * fraction;
    }
    return output;
  }

  /// Maps VitalDataRecord fields to a flat list of doubles based on signal label.
  static List<double> _extractRawValues(VitalDataRecord record, String label,
      int expectedFs) {
    switch (label) {
      case 'spo2':
        return [record.spo2.toDouble()];
      case 'pulse':
        return [record.heartRate.toDouble()];
      case 'battery':
        return [record.battery.toDouble()];
      case 'charge_state':
        return [record.chargeState.toDouble()];
      case 'signal_quality':
        return [record.signalQuality.toDouble()];
      case 'sensor_status':
        return [record.sensorStatus.toDouble()];
      case 'ppg':
        return record.ppgSignal.map((e) => e.toDouble()).toList();
      case 'HRV':
        return [record.hrv.toDouble()];
      case 'derived_effort':
        return [record.derivedEffort.toDouble()];
      case 'derived_flow':
        return [record.derivedFlow.toDouble()];
      default:
        return List.filled(expectedFs, 0.0);
    }
  }

  static void _ensureDirectoryExists(String path) {
    final file = File(path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
  }

  static String _sanitize(String input) =>
      input.replaceAll(RegExp(r'[^\x00-\x7F]'), '');
}

/// Define the structure for a single EDF signal using a Dart Record for clarity.
typedef EdfSignal = ({
String label,
String unit,
int fs,
double physMin,
double physMax,
int digMin,
int digMax,
});
