import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Load the correct library depending on platform
DynamicLibrary _loadLibrary() {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libedflib.so');
  } else if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('edflib.dll');
  } else {
    throw UnsupportedError('Unsupported platform');
  }
}

final DynamicLibrary edfLib = _loadLibrary();

// Filetype constants from  edflib.h
const int EDFLIB_FILETYPE_EDF = 0;
const int EDFLIB_FILETYPE_EDFPLUS = 1;
const int EDFLIB_FILETYPE_BDF = 2;
const int EDFLIB_FILETYPE_BDFPLUS = 3;

/// Define structs
final class EdflibHdr extends Struct {
  @Int32()
  external int handle;

  @Int32()
  external int filetype;

  @Int32()
  external int edfsignals;
}

final class EdflibParam extends Struct {
  @Array(17)
  external Array<Int8> label;
}

/// FFI Function definitions
// Open file for reading (not used in current flow, but provided for completeness)
typedef edfopen_file_readonly_native =
    Int32 Function(
      Pointer<Utf8> path,
      Pointer<EdflibHdr> edfhdr,
      Int32 readAnnotations,
    );
typedef EdfOpenFileReadonly =
    int Function(
      Pointer<Utf8> path,
      Pointer<EdflibHdr> edfhdr,
      int readAnnotations,
    );

final EdfOpenFileReadonly edfOpenFileReadonly = edfLib
    .lookupFunction<edfopen_file_readonly_native, EdfOpenFileReadonly>(
      'edfopen_file_readonly',
    );

typedef edfread_physical_samples_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Int32 n, Pointer<Double> buf);
typedef EdfReadPhysicalSamples =
    int Function(int handle, int edfsignal, int n, Pointer<Double> buf);

final EdfReadPhysicalSamples edfReadPhysicalSamples = edfLib
    .lookupFunction<edfread_physical_samples_native, EdfReadPhysicalSamples>(
      'edfread_physical_samples',
    );

typedef edfclose_file_native = Int32 Function(Int32 handle);
typedef EdfCloseFile = int Function(int handle);

final EdfCloseFile edfCloseFile = edfLib
    .lookupFunction<edfclose_file_native, EdfCloseFile>('edfclose_file');

// edfopen_file_writeonly_with_params
typedef edfopen_file_writeonly_with_params_native =
    Int32 Function(
      Pointer<Utf8> path,
      Int32 filetype,
      Int32 number_of_signals,
      Int32 samplefrequency,
      Double phys_max_min,
      Pointer<Utf8> phys_dim,
    );

typedef EdfOpenFileWriteonlyWithParams =
    int Function(
      Pointer<Utf8> path,
      int filetype,
      int number_of_signals,
      int samplefrequency,
      double phys_max_min,
      Pointer<Utf8> phys_dim,
    );

final EdfOpenFileWriteonlyWithParams edfOpenFileWriteonlyWithParams = edfLib
    .lookup<NativeFunction<edfopen_file_writeonly_with_params_native>>(
      'edfopen_file_writeonly_with_params',
    )
    .asFunction();

// edfopen_file_writeonly (for per-signal custom params)
typedef edfopen_file_writeonly_native =
    Int32 Function(Pointer<Utf8> path, Int32 filetype, Int32 number_of_signals);

typedef EdfOpenFileWriteonly =
    int Function(Pointer<Utf8> path, int filetype, int number_of_signals);

final EdfOpenFileWriteonly edfOpenFileWriteonly = edfLib
    .lookup<NativeFunction<edfopen_file_writeonly_native>>(
      'edfopen_file_writeonly',
    )
    .asFunction();

// Per-signal setters
typedef edf_set_samplefrequency_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Int32 samplefrequency);
typedef EdfSetSamplefrequency =
    int Function(int handle, int edfsignal, int samplefrequency);

final EdfSetSamplefrequency edfSetSamplefrequency = edfLib
    .lookupFunction<edf_set_samplefrequency_native, EdfSetSamplefrequency>(
      'edf_set_samplefrequency',
    );

typedef edf_set_physical_maximum_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Double phys_max);
typedef EdfSetPhysicalMaximum =
    int Function(int handle, int edfsignal, double phys_max);

final EdfSetPhysicalMaximum edfSetPhysicalMaximum = edfLib
    .lookupFunction<edf_set_physical_maximum_native, EdfSetPhysicalMaximum>(
      'edf_set_physical_maximum',
    );

typedef edf_set_physical_minimum_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Double phys_min);
typedef EdfSetPhysicalMinimum =
    int Function(int handle, int edfsignal, double phys_min);

final EdfSetPhysicalMinimum edfSetPhysicalMinimum = edfLib
    .lookupFunction<edf_set_physical_minimum_native, EdfSetPhysicalMinimum>(
      'edf_set_physical_minimum',
    );

typedef edf_set_digital_maximum_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Int32 dig_max);
typedef EdfSetDigitalMaximum =
    int Function(int handle, int edfsignal, int dig_max);

final EdfSetDigitalMaximum edfSetDigitalMaximum = edfLib
    .lookupFunction<edf_set_digital_maximum_native, EdfSetDigitalMaximum>(
      'edf_set_digital_maximum',
    );

typedef edf_set_digital_minimum_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Int32 dig_min);
typedef EdfSetDigitalMinimum =
    int Function(int handle, int edfsignal, int dig_min);

final EdfSetDigitalMinimum edfSetDigitalMinimum = edfLib
    .lookupFunction<edf_set_digital_minimum_native, EdfSetDigitalMinimum>(
      'edf_set_digital_minimum',
    );

typedef edf_set_label_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Pointer<Utf8> label);
typedef EdfSetLabel =
    int Function(int handle, int edfsignal, Pointer<Utf8> label);

final EdfSetLabel edfSetLabel = edfLib
    .lookupFunction<edf_set_label_native, EdfSetLabel>('edf_set_label');

typedef edf_set_physical_dimension_native =
    Int32 Function(Int32 handle, Int32 edfsignal, Pointer<Utf8> phys_dim);
typedef EdfSetPhysicalDimension =
    int Function(int handle, int edfsignal, Pointer<Utf8> phys_dim);

final EdfSetPhysicalDimension edfSetPhysicalDimension = edfLib
    .lookupFunction<edf_set_physical_dimension_native, EdfSetPhysicalDimension>(
      'edf_set_physical_dimension',
    );

// Set datarecord duration (seconds)
typedef edf_set_datarecord_duration_native =
    Int32 Function(Int32 handle, Int32 duration);
typedef EdfSetDatarecordDuration = int Function(int handle, int duration);

final EdfSetDatarecordDuration edfSetDatarecordDuration = edfLib
    .lookupFunction<
      edf_set_datarecord_duration_native,
      EdfSetDatarecordDuration
    >('edf_set_datarecord_duration');

// Set start datetime
typedef edf_set_startdatetime_native =
    Int32 Function(
      Int32 handle,
      Int32 year,
      Int32 month,
      Int32 day,
      Int32 hour,
      Int32 minute,
      Int32 second,
    );
typedef EdfSetStartdatetime =
    int Function(
      int handle,
      int year,
      int month,
      int day,
      int hour,
      int minute,
      int second,
    );

// 1. Define the C Function Signature (Native Type)
// int function(int handle, char* value)
typedef EdfSetStringNative = Int32 Function(Int32 hdl, Pointer<Utf8> value);

// 2. Define the Dart Function Signature (Dart Type)
// int function(int handle, Pointer<Utf8> value)
typedef EdfSetStringDart = int Function(int hdl, Pointer<Utf8> value);

final EdfSetStartdatetime edfSetStartdatetime = edfLib
    .lookupFunction<edf_set_startdatetime_native, EdfSetStartdatetime>(
      'edf_set_startdatetime',
    );

// Optional metadata setters
typedef edf_set_patientname_native =
    Int32 Function(Int32 handle, Pointer<Utf8> name);
typedef EdfSetPatientname = int Function(int handle, Pointer<Utf8> name);

final EdfSetPatientname edfSetPatientname = edfLib
    .lookupFunction<edf_set_patientname_native, EdfSetPatientname>(
      'edf_set_patientname',
    );

typedef edf_set_recording_additional_native =
    Int32 Function(Int32 handle, Pointer<Utf8> rec);
typedef EdfSetRecordingAdditional = int Function(int handle, Pointer<Utf8> rec);

final EdfSetRecordingAdditional edfSetRecordingAdditional = edfLib
    .lookupFunction<
      edf_set_recording_additional_native,
      EdfSetRecordingAdditional
    >('edf_set_recording_additional');

final edfSetPatientCode = edfLib
    .lookupFunction<edf_set_patientname_native, EdfSetPatientname>(
      'edf_set_patientcode',
    );
final edfSetPatientAdditional = edfLib
    .lookupFunction<EdfSetStringNative, EdfSetStringDart>(
      'edf_set_patient_additional',
    );
final edfSetGender = edfLib
    .lookupFunction<EdfSetStringNative, EdfSetStringDart>('edf_set_gender');
// final edfSetDeviceAndRecorderInfo = edfLib.lookupFunction<EdfSetStringNative, EdfSetStringDart>(
//     'edf_set_device_and_recorder_info');

// For edf_set_birthdate
typedef EdfSetBirthdateNative = Int32 Function(Int32, Int32, Int32, Int32);
typedef EdfSetBirthdateDart = int Function(int, int, int, int);

final edfSetBirthdate = edfLib
    .lookupFunction<EdfSetBirthdateNative, EdfSetBirthdateDart>(
      'edf_set_birthdate',
    );

// Writing samples (digital short is convenient for 16-bit EDF)
typedef edfwrite_digital_short_samples_native =
    Int32 Function(Int32 handle, Pointer<Int16> buf);
typedef EdfWriteDigitalShortSamples =
    int Function(int handle, Pointer<Int16> buf);

final EdfWriteDigitalShortSamples edfwriteDigitalShortSamples = edfLib
    .lookupFunction<
      edfwrite_digital_short_samples_native,
      EdfWriteDigitalShortSamples
    >('edfwrite_digital_short_samples');

// Blockwrite digital short (all signals per record). With 1 signal it's equivalent.
typedef edf_blockwrite_digital_short_samples_native =
    Int32 Function(Int32 handle, Pointer<Int16> buf);
typedef EdfBlockwriteDigitalShortSamples =
    int Function(int handle, Pointer<Int16> buf);

final EdfBlockwriteDigitalShortSamples edfBlockwriteDigitalShortSamples = edfLib
    .lookupFunction<
      edf_blockwrite_digital_short_samples_native,
      EdfBlockwriteDigitalShortSamples
    >('edf_blockwrite_digital_short_samples');

// Write annotations (EDF+)
typedef edfwrite_annotation_utf8_hr_native =
    Int32 Function(
      Int32 handle,
      LongLong onset,
      LongLong duration,
      Pointer<Utf8> description,
    );
typedef EdfwriteAnnotationUtf8Hr =
    int Function(
      int handle,
      int onset,
      int duration,
      Pointer<Utf8> description,
    );

final EdfwriteAnnotationUtf8Hr edfwriteAnnotationUtf8Hr = edfLib
    .lookupFunction<
      edfwrite_annotation_utf8_hr_native,
      EdfwriteAnnotationUtf8Hr
    >('edfwrite_annotation_utf8_hr');
