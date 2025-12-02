import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:fftea/fftea.dart';
import 'package:collection/collection.dart';
import 'audio_service.dart';

void main() {
  runApp(const TunerApp());
}

class TunerApp extends StatelessWidget {
  const TunerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(360, 800),
      minTextAdapt: true,
      splitScreenMode: true,
      child: MaterialApp(
        title: 'Precision Tuner',
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: Colors.blueAccent,
          colorScheme: ColorScheme.dark(
            primary: Colors.blueAccent,
            secondary: Colors.cyanAccent,
            surface: const Color(0xFF1E1E1E),
            background: const Color(0xFF121212),
          ),
          scaffoldBackgroundColor: const Color(0xFF121212),
          useMaterial3: true,
          fontFamily: 'Inter',
        ),
        home: const TunerPage(),
      ),
    );
  }
}

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  late final AudioService _audioService;
  late final ToneGeneratorService _toneGenerator;
  final _pitchDetector = PitchDetector();

  String _note = '';
  String _status = 'Start Tuning';
  double _pitch = 0.0;
  double _cents = 0.0;
  bool _isListening = false;
  Timer? _timer;

  double _a4Frequency = 440.0;
  Instrument _selectedInstrument = Instrument.guitar;
  Map<String, double> _standardPitches = {};

  List<double> _fftData = [];
  final QueueList<double> _pitchHistory = QueueList<double>(100);

  bool _isGeneratingTone = false;
  String? _currentlyPlayingNote;

  static const Map<Instrument, List<String>> _instrumentTunings = {
    Instrument.guitar: ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    Instrument.cello: ['C2', 'G2', 'D3', 'A3'],
    Instrument.bass: ['E1', 'A1', 'D2', 'G2'],
    Instrument.violin: ['G3', 'D4', 'A4', 'E5'],
  };

  @override
  void initState() {
    super.initState();
    _audioService = AudioService.create();
    _toneGenerator = ToneGeneratorService.create();
    WidgetsBinding.instance.addObserver(this);
    _recalculatePitches();
    for (int i = 0; i < 100; i++) {
      _pitchHistory.add(0);
    }
    _audioService.init();
    _toneGenerator.init();
  }

  @override
  void dispose() {
    _stopCapture();
    _toneGenerator.dispose();
    _audioService.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopCapture();
      _stopToneGenerator();
    } else if (state == AppLifecycleState.resumed && _isListening) {
      _startCapture();
    }
  }

  Future<void> _toggleListening() async {
    if (_isGeneratingTone) _stopToneGenerator();
    if (_isListening) {
      _stopCapture();
    } else {
      await _startCapture();
    }
  }

  Future<void> _startCapture() async {
    if (await _audioService.hasPermission()) {
      await _audioService.startListening((data) => _processAudioData(data));
      setState(() => _isListening = true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (mounted && _isListening) {
          setState(() {
            _note = '';
            _status = 'Listening...';
            _pitch = 0;
            _cents = 0;
          });
        }
      });
    } else {
      setState(() => _status = 'Microphone permission denied');
    }
  }

  void _processAudioData(Uint8List data) async {
    final floatData = <double>[];
    for (int i = 0; i < data.length - 1; i += 2) {
      final int sample = data[i] | (data[i + 1] << 8);
      final int signedSample = sample > 32767 ? sample - 65536 : sample;
      floatData.add(signedSample / 32768.0);
    }
    if (floatData.length < 2048) return;

    try {
      final result = await _pitchDetector.getPitchFromFloatBuffer(floatData);
      if (result.pitched && result.probability > 0.9) {
        _updatePitch(result.pitch);
      }
    } catch (e) {}

    const fftSize = 2048;
    final paddedSample = List<double>.filled(fftSize, 0.0);
    for (int i = 0; i < floatData.length && i < fftSize; i++) {
      paddedSample[i] = floatData[i];
    }
    final fft = FFT(fftSize);
    final fftResult = fft.realFft(paddedSample);
    if (mounted) {
      setState(
          () => _fftData = fftResult.discardConjugates().magnitudes().toList());
    }
  }

  void _stopCapture() async {
    await _audioService.stopListening();
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _note = '';
        _pitch = 0.0;
        _cents = 0.0;
        _isListening = false;
        _status = 'Start Tuning';
        _fftData = [];
      });
    }
  }

  void _updatePitch(double detectedPitch) {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isListening) {
        setState(() {
          _note = '';
          _status = 'Listening...';
          _pitch = 0;
          _cents = 0;
        });
      }
    });

    if (!mounted || detectedPitch <= 0) return;

    String closestNote = '';
    double minDifference = double.infinity;
    double targetFrequency = 0;

    _standardPitches.forEach((note, frequency) {
      final difference = (detectedPitch - frequency).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closestNote = note;
        targetFrequency = frequency;
      }
    });

    final centsDifference =
        1200 * (math.log(detectedPitch / targetFrequency) / math.log(2));
    if (_pitchHistory.length >= 100) _pitchHistory.removeFirst();
    _pitchHistory.add(centsDifference.clamp(-50, 50));

    setState(() {
      _pitch = detectedPitch;
      _note = closestNote;
      _cents = centsDifference;
      if (centsDifference.abs() < 5) {
        _status = 'In Tune ✓';
      } else if (centsDifference > 5) {
        _status = 'Too Sharp ↑';
      } else {
        _status = 'Too Flat ↓';
      }
    });
  }

  void _recalculatePitches() {
    const Map<String, int> noteOffsets = {
      'A0': -48,
      'A#0': -47,
      'B0': -46,
      'C1': -45,
      'C#1': -44,
      'D1': -43,
      'D#1': -42,
      'E1': -41,
      'F1': -40,
      'F#1': -39,
      'G1': -38,
      'G#1': -37,
      'A1': -36,
      'A#1': -35,
      'B1': -34,
      'C2': -33,
      'C#2': -32,
      'D2': -31,
      'D#2': -30,
      'E2': -29,
      'F2': -28,
      'F#2': -27,
      'G2': -26,
      'G#2': -25,
      'A2': -24,
      'A#2': -23,
      'B2': -22,
      'C3': -21,
      'C#3': -20,
      'D3': -19,
      'D#3': -18,
      'E3': -17,
      'F3': -16,
      'F#3': -15,
      'G3': -14,
      'G#3': -13,
      'A3': -12,
      'A#3': -11,
      'B3': -10,
      'C4': -9,
      'C#4': -8,
      'D4': -7,
      'D#4': -6,
      'E4': -5,
      'F4': -4,
      'F#4': -3,
      'G4': -2,
      'G#4': -1,
      'A4': 0,
      'A#4': 1,
      'B4': 2,
      'C5': 3,
      'C#5': 4,
      'D5': 5,
      'D#5': 6,
      'E5': 7,
      'F5': 8,
      'F#5': 9,
      'G5': 10,
      'G#5': 11,
      'A5': 12,
      'A#5': 13,
      'B5': 14,
      'C6': 15,
    };
    _standardPitches.clear();
    noteOffsets.forEach((note, offset) {
      _standardPitches[note] = _a4Frequency * math.pow(2, offset / 12.0);
    });
  }

  void _toggleToneGenerator(String note) {
    if (_isListening) _stopCapture();
    if (_currentlyPlayingNote == note) {
      _stopToneGenerator();
    } else {
      final frequency = _standardPitches[note];
      if (frequency != null) {
        _toneGenerator.playNote(frequency);
        setState(() {
          _currentlyPlayingNote = note;
          _isGeneratingTone = true;
          _status = 'Playing ${note.replaceAll(RegExp(r'[0-9]'), '')}';
        });
      }
    }
  }

  void _stopToneGenerator() {
    _toneGenerator.stopNote();
    setState(() {
      _currentlyPlayingNote = null;
      _isGeneratingTone = false;
      _status = 'Start Tuning';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF121212),
              Color(0xFF1E1E1E),
              Color(0xFF121212),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
            child: Column(
              children: [
                // Header
                _buildHeader(),
                SizedBox(height: 16.h),

                // Main content in scrollable area
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      children: [
                        // Main Note Display
                        _buildNoteDisplay(),
                        SizedBox(height: 24.h),

                        // Tuning Meter
                        _buildTuningMeter(),
                        SizedBox(height: 16.h),

                        // Frequency Display
                        _buildFrequencyDisplay(),
                        SizedBox(height: 24.h),

                        // String Indicators
                        _buildStringIndicators(),
                        SizedBox(height: 24.h),

                        // Visualizations
                        _buildVisualizations(),
                        SizedBox(height: 24.h),
                      ],
                    ),
                  ),
                ),

                // Controls (fixed at bottom)
                _buildControls(),
                SizedBox(height: 8.h),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PRECISION TUNER',
              style: TextStyle(
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
                letterSpacing: 1.5,
              ),
            ),
            Text(
              _selectedInstrument.name.capitalize(),
              style: TextStyle(
                fontSize: 16.sp,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        _buildSettingsButton(),
      ],
    );
  }

  Widget _buildNoteDisplay() {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 16.h),
          constraints: BoxConstraints(
            minWidth: 200.w,
            maxWidth: 300.w,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _getStatusColor().withOpacity(0.3),
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _note.replaceAll(RegExp(r'[0-9]'), '').isEmpty
                      ? '-'
                      : _note.replaceAll(RegExp(r'[0-9]'), ''),
                  style: TextStyle(
                    fontSize: 64.sp,
                    fontWeight: FontWeight.w800,
                    color: _getStatusColor(),
                    height: 1,
                  ),
                ),
              ),
              SizedBox(height: 8.h),
              Text(
                _status,
                style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w600,
                  color: _getStatusColor().withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTuningMeter() {
    _cents.clamp(-50.0, 50.0);

    return Column(
      children: [
        // Meter labels
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('-50',
                  style: TextStyle(color: Colors.white54, fontSize: 12.sp)),
              Text('0',
                  style: TextStyle(color: Colors.white54, fontSize: 12.sp)),
              Text('+50',
                  style: TextStyle(color: Colors.white54, fontSize: 12.sp)),
            ],
          ),
        ),
        SizedBox(height: 8.h),

        // Main meter
        Container(
          width: double.infinity,
          constraints: BoxConstraints(maxWidth: 320.w),
          height: 48.h,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.blue.shade400,
                Colors.green.shade400,
                Colors.blue.shade400,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Stack(
            children: [
              // Center line
              Center(
                child: Container(
                  width: 2,
                  height: 48.h,
                  color: Colors.white.withOpacity(0.3),
                ),
              ),

              // Needle
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                left: (_cents.clamp(-50.0, 50.0) + 50) / 100 * (320.w - 48),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 48.w,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _getStatusColor(),
                    boxShadow: [
                      BoxShadow(
                        color: _getStatusColor().withOpacity(0.6),
                        blurRadius: 12,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 4.w,
                      height: 24.h,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFrequencyDisplay() {
    return Text(
      _pitch > 0 ? '${_pitch.toStringAsFixed(2)} Hz' : '-- Hz',
      style: TextStyle(
        fontSize: 18.sp,
        fontWeight: FontWeight.w600,
        color: Colors.white70,
      ),
    );
  }

  Widget _buildStringIndicators() {
    List<String> strings = _instrumentTunings[_selectedInstrument]!;

    return Container(
      padding: EdgeInsets.all(16.r),
      constraints: BoxConstraints(maxWidth: 400.w),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'STRING TUNING',
            style: TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w600,
              color: Colors.white54,
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(height: 16.h),
          Wrap(
            spacing: 8.w,
            runSpacing: 8.h,
            alignment: WrapAlignment.center,
            children: strings.map((stringNote) {
              final bool isCurrentNote = _note == stringNote;
              final bool isInTune = isCurrentNote && _status == 'In Tune ✓';
              final bool isPlayingThisTone =
                  _currentlyPlayingNote == stringNote;

              return _StringIndicator(
                note: stringNote.replaceAll(RegExp(r'[0-9]'), ''),
                isActive: isCurrentNote,
                isInTune: isInTune,
                isPlaying: isPlayingThisTone,
                onTap: () => _toggleToneGenerator(stringNote),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualizations() {
    return Container(
      padding: EdgeInsets.all(16.r),
      constraints: BoxConstraints(maxWidth: 400.w),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ANALYTICS',
                style: TextStyle(
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                  color: Colors.white54,
                  letterSpacing: 1.2,
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'LIVE',
                  style: TextStyle(
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w600,
                    color: Colors.blueAccent,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text('Pitch History',
                        style:
                            TextStyle(color: Colors.white60, fontSize: 12.sp)),
                    SizedBox(height: 8.h),
                    Container(
                      height: 100.h,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox.expand(
                          child: CustomPaint(
                            painter: PitchHistoryPainter(
                                _pitchHistory.toList(), Colors.blueAccent),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  children: [
                    Text('Frequency Spectrum',
                        style:
                            TextStyle(color: Colors.white60, fontSize: 12.sp)),
                    SizedBox(height: 8.h),
                    Container(
                      height: 100.h,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox.expand(
                          child: CustomPaint(
                            painter: FFTPainter(_fftData, Colors.cyanAccent),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final bool isActionDisabled = _isListening || _isGeneratingTone;

    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'REFERENCE TONE',
                  style: TextStyle(
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                    letterSpacing: 1.2,
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  'A4: ${_a4Frequency.toStringAsFixed(1)} Hz',
                  style: TextStyle(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4.h,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: 8.r,
                      disabledThumbRadius: 6.r,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: 16.r,
                    ),
                    activeTrackColor: Colors.blueAccent,
                    inactiveTrackColor: Colors.white12,
                    thumbColor: Colors.blueAccent,
                    overlayColor: Colors.blueAccent.withOpacity(0.2),
                  ),
                  child: Slider(
                    value: _a4Frequency,
                    min: 415,
                    max: 465,
                    divisions: 500,
                    onChanged: isActionDisabled
                        ? null
                        : (value) {
                            setState(() {
                              _a4Frequency = value;
                              _recalculatePitches();
                            });
                          },
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16.w),
          _buildMicrophoneButton(),
        ],
      ),
    );
  }

  Widget _buildSettingsButton() {
    return PopupMenuButton<Instrument>(
      onSelected: (Instrument? newValue) {
        if (newValue != null && !_isListening && !_isGeneratingTone) {
          setState(() => _selectedInstrument = newValue);
        }
      },
      itemBuilder: (BuildContext context) =>
          Instrument.values.map((instrument) {
        return PopupMenuItem<Instrument>(
          value: instrument,
          child: Text(
            instrument.name.capitalize(),
            style: TextStyle(fontSize: 14.sp),
          ),
        );
      }).toList(),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: EdgeInsets.all(12.r),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(Icons.tune, color: Colors.white70, size: 20.r),
      ),
    );
  }

  Widget _buildMicrophoneButton() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (_isListening ? Colors.redAccent : Colors.blueAccent)
                .withOpacity(0.4),
            blurRadius: 15,
            spreadRadius: 3,
          ),
        ],
      ),
      child: FloatingActionButton(
        onPressed: _toggleListening,
        backgroundColor: _isListening ? Colors.redAccent : Colors.blueAccent,
        foregroundColor: Colors.white,
        elevation: 8,
        child: Icon(
          _isListening ? Icons.mic_off : Icons.mic,
          size: 28.r,
        ),
      ),
    );
  }

  Color _getStatusColor() {
    if (_status == 'In Tune ✓') return Colors.greenAccent;
    if (_status == 'Start Tuning' || _status == 'Listening...')
      return Colors.white70;
    if (_isGeneratingTone) return Colors.cyanAccent;
    return Colors.blueAccent;
  }
}

class _StringIndicator extends StatelessWidget {
  final String note;
  final bool isActive;
  final bool isInTune;
  final bool isPlaying;
  final VoidCallback onTap;

  const _StringIndicator({
    required this.note,
    required this.isActive,
    required this.isInTune,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60.w,
        constraints: BoxConstraints(minWidth: 50.w, maxWidth: 70.w),
        padding: EdgeInsets.symmetric(vertical: 12.h),
        decoration: BoxDecoration(
          color: isPlaying
              ? Colors.cyanAccent.withOpacity(0.2)
              : isActive
                  ? Colors.blueAccent.withOpacity(0.2)
                  : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isInTune
                ? Colors.greenAccent
                : isActive
                    ? Colors.blueAccent
                    : Colors.white12,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                note,
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                  color: isInTune
                      ? Colors.greenAccent
                      : isActive
                          ? Colors.blueAccent
                          : Colors.white70,
                ),
              ),
            ),
            SizedBox(height: 6.h),
            Icon(
              isPlaying ? Icons.stop : Icons.play_arrow,
              size: 16.r,
              color: isPlaying ? Colors.cyanAccent : Colors.white54,
            ),
          ],
        ),
      ),
    );
  }
}

class FFTPainter extends CustomPainter {
  final List<double> fftData;
  final Color color;

  FFTPainter(this.fftData, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (fftData.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double barWidth = size.width / (fftData.length / 8);
    final double maxMagnitude =
        fftData.sublist(0, fftData.length ~/ 2).reduce(math.max);

    if (maxMagnitude <= 0 || maxMagnitude.isNaN || maxMagnitude.isInfinite) {
      return;
    }

    for (int i = 0; i < fftData.length / 8; i++) {
      final double magnitude = fftData[i];
      final double barHeight = (magnitude / maxMagnitude) * size.height;

      if (barHeight.isNaN || barHeight.isInfinite || barHeight < 0) {
        continue;
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              i * barWidth, size.height - barHeight, barWidth * 0.8, barHeight),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PitchHistoryPainter extends CustomPainter {
  final List<double> pitchHistory;
  final Color color;

  PitchHistoryPainter(this.pitchHistory, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    final double stepX = size.width / (pitchHistory.length - 1);
    for (int i = 0; i < pitchHistory.length; i++) {
      final y = size.height / 2 - (pitchHistory[i] / 50.0) * (size.height / 2);
      if (i == 0) {
        path.moveTo(i * stepX, y);
      } else {
        path.lineTo(i * stepX, y);
      }
    }
    final centerLinePaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      centerLinePaint,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

enum Instrument { guitar, cello, bass, violin }

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}
