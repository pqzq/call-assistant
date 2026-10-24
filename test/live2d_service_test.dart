import 'package:call_assistant/services/live2d_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Live2D 模型文件识别', () {
    test('按后缀识别 *.model3.json（大小写不敏感）', () {
      expect(Live2dService.isModelDescriptionFile('Hiyori.model3.json'), isTrue);
      expect(Live2dService.isModelDescriptionFile('hiyori/Hiyori.model3.json'), isTrue);
      expect(Live2dService.isModelDescriptionFile('MODEL3.JSON'), isTrue);
      expect(Live2dService.isModelDescriptionFile('Haru.Model3.Json'), isTrue);
    });

    test('后缀不标准时按内容兜底', () {
      const model = '{"FileReferences":{"Moc":"Ren.moc3","Textures":["t.png"]}}';
      expect(Live2dService.isModelDescriptionFile('model.json', content: model), isTrue);
      expect(Live2dService.isModelDescriptionFile('config.json', content: model), isTrue);
    });

    test('普通 json / 非 json 不算模型文件', () {
      expect(Live2dService.isModelDescriptionFile('config.json'), isFalse);
      expect(
        Live2dService.isModelDescriptionFile('config.json', content: '{"foo":1}'),
        isFalse,
      );
      expect(Live2dService.isModelDescriptionFile('texture.png'), isFalse);
      expect(Live2dService.isModelDescriptionFile('notes.txt'), isFalse);
    });

    test('展示名去掉模型后缀', () {
      expect(Live2dService.modelNameOf('haru/Haru.model3.json'), 'Haru');
      expect(Live2dService.modelNameOf('hiyori/Hiyori.model3.json'), 'Hiyori');
      expect(Live2dService.modelNameOf('models/my.model3.json'), 'my');
    });
  });

  group('模型文件识别（文件夹导入用）', () {
    test('任意层级的 model3.json 都能被识别', () {
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/Haru.model3.json'), isTrue);
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/B/C/Haru.model3.json'), isTrue);
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/model3.json'), isTrue);
    });

    test('同目录的其它文件不会被当成模型描述文件', () {
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/texture_00.png'), isFalse);
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/ Haru.moc3'), isFalse);
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/readme.txt'), isFalse);
    });

    test('大小写不同的后缀也能识别', () {
      expect(Live2dService.isModelDescriptionFile('/sdcard/A/Haru.MODEL3.JSON'), isTrue);
    });
  });}
