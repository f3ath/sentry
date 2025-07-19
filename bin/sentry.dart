import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:intl/intl.dart';

const defaultDateFormat = 'yyyy-MM-dd-HH-mm-ss-S';

void main(List<String> args) async {
  final p = ArgParser()
    ..addOption('source', abbr: 's', help: 'RTSP stream URL', mandatory: true)
    ..addOption(
      'destination',
      abbr: 'd',
      help: 'Destination directory',
      mandatory: false,
      defaultsTo: '.',
    );
  final opts = p.parse(args);

  final writer = StreamWriter(
    sourceUrl: opts.option('source')!,
    chunkSize: const Duration(hours: 1),
    destinationDir: opts.option('destination')!,
  );

  final finished = writer.start();

  ProcessSignal.sigint.watch().listen((event) async {
    print('Ctrl-C detected');
    writer.stop();
    print('stopping...');
    await finished;
    exit(0);
  });
}

class StreamWriter {
  StreamWriter({
    required this.sourceUrl,
    required this.chunkSize,
    required this.destinationDir,
  });

  final String sourceUrl;
  final String destinationDir;
  final Duration chunkSize;
  bool _active = true;

  Process? _proc;

  /// Starts the writing process, returns the status stream
  Future<void> start() async {
    Object? lastValue;
    DateTime lastUpdated = DateTime.now();
    final watcher = Timer.periodic(const Duration(seconds: 1), (_) {
      final p = _proc;
      if (p != null &&
          lastUpdated
              .add(const Duration(seconds: 2))
              .isBefore(DateTime.now())) {
        print('Oh shit! Terminating pid ${p.pid}');
        final delivered = p.kill(ProcessSignal.sigterm);
        print('Signal delivered: $delivered');
      }
    });

    while (_active) {
      lastUpdated = DateTime.now();
      final p =
          await Process.start('ffmpeg', [
              '-y',
              '-rtsp_transport',
              'tcp',
              '-i',
              sourceUrl,
              '-c:a',
              'aac',
              '-c:v',
              'copy',
              '-f',
              'mpegts',
              '-t',
              '${chunkSize.inSeconds}',
              '-progress',
              'pipe:1',
              '$destinationDir/${DateFormat(defaultDateFormat).format(DateTime.now())}.ts',
            ])
            ..stderr.listen((_) {})
            ..stdout
                .transform(utf8.decoder)
                .map(const LineSplitter().convert)
                .map(
                  (lines) => Map.fromEntries(
                    lines
                        .map((line) => line.split('='))
                        .map((pair) => MapEntry(pair[0], pair[1])),
                  ),
                )
                .map((it) => it['frame'])
                .forEach((value) {
                  if (lastValue != value) {
                    lastUpdated = DateTime.now();
                    lastValue = value;
                  }
                });
      _proc = p;
      await p.exitCode;
    }
    watcher.cancel();
  }

  void stop() {
    _active = false;
    _proc?.kill(ProcessSignal.sigterm);
  }
}
