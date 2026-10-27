import 'package:call_assistant/services/asr_recognizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆盖 ASR 模型目录的架构判定（`AsrRecognizer.classifyFiles`）
///
/// 这些用例对应 sherpa-onnx 官方那几个模型包解压后的真实结构 ——
/// 判定错了会表现成「导入成功但识别用不了」，或者干脆「导入失败」。
void main() {
  test('sense-voice：单文件 + tokens，目录名含 sense', () {
    final files = AsrRecognizer.classifyFiles(
      <String>['model.int8.onnx', 'tokens.txt'],
      '/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17',
    );
    expect(files, isNotNull);
    expect(files!.arch, AsrArch.senseVoice);
    expect(files.model, 'model.int8.onnx');
    expect(files.tokens, 'tokens.txt');
  });

  test('paraformer：单文件 + tokens，目录名不含 sense', () {
    final files = AsrRecognizer.classifyFiles(
      <String>['model.int8.onnx', 'tokens.txt'],
      '/models/sherpa-onnx-paraformer-zh-small-2024-03-09',
    );
    expect(files, isNotNull);
    expect(files!.arch, AsrArch.paraformer);
    expect(files.model, 'model.int8.onnx');
  });

  test('zipformer（transducer）：encoder + decoder + joiner', () {
    final files = AsrRecognizer.classifyFiles(
      <String>[
        'encoder-epoch-99-avg-1.int8.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.int8.onnx',
        'tokens.txt',
      ],
      '/models/sherpa-onnx-zipformer-zh-14M',
    );
    expect(files, isNotNull);
    expect(files!.arch, AsrArch.transducer);
    expect(files.encoder, contains('encoder'));
    expect(files.decoder, contains('decoder'));
    expect(files.joiner, contains('joiner'));
  });

  test('whisper：encoder + decoder，tokens 文件名带前缀', () {
    final files = AsrRecognizer.classifyFiles(
      <String>[
        'tiny-encoder.onnx',
        'tiny-decoder.onnx',
        'tiny-tokens.txt',
      ],
      '/models/sherpa-onnx-whisper-tiny',
    );
    expect(files, isNotNull);
    expect(files!.arch, AsrArch.whisper);
    expect(files.tokens, 'tiny-tokens.txt');
  });

  test('缺 tokens.txt -> 不可用', () {
    expect(
      AsrRecognizer.classifyFiles(
        <String>['model.int8.onnx'],
        '/models/sherpa-onnx-sense-voice-x',
      ),
      isNull,
    );
  });

  test('缺 onnx -> 不可用', () {
    expect(
      AsrRecognizer.classifyFiles(
        <String>['tokens.txt'],
        '/models/sherpa-onnx-sense-voice-x',
      ),
      isNull,
    );
  });

  test('transducer 只有 encoder+decoder（缺 joiner）-> 不可用', () {
    expect(
      AsrRecognizer.classifyFiles(
        <String>['encoder.onnx', 'decoder.onnx', 'tokens.txt'],
        '/models/sherpa-onnx-zipformer-x',
      ),
      isNull,
    );
  });

  test('vocoder.onnx 不参与主模型判定', () {
    final files = AsrRecognizer.classifyFiles(
      <String>['model.onnx', 'vocoder.onnx', 'tokens.txt'],
      '/models/some-tts-like-dir',
    );
    expect(files, isNotNull);
    // 不是 ASR 的声码器模型，但按单文件族处理 —— 主模型必须是 model.onnx
    expect(files!.model, 'model.onnx');
  });
}
