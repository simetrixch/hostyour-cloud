import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// What helm produced, read as the set of resources an API server would be handed.
///
/// helm answers for the template language and says nothing about what comes out of it: a document
/// missing its apiVersion, its kind or its name is a valid YAML document and a rejected resource.
/// A chart can render a whole file of them and helm exits zero.
@immutable
final class RenderedManifest {
  /// The manifest [text] helm wrote.
  const RenderedManifest(this.text);

  /// What helm wrote.
  final String text;

  /// What no API server would accept, as `<document number>` against what it has not got.
  ///
  /// Null documents are passed over. A chart that renders an empty conditional block emits one, and
  /// it is nothing — reporting it would make every second chart red for a `{{- if }}` that was
  /// false.
  Map<int, List<String>> get rejections {
    final List<YamlDocument> documents;
    try {
      documents = loadYamlDocuments(text);
    } on YamlException catch (error) {
      return <int, List<String>>{
        1: <String>['is not YAML at all: $error'],
      };
    }

    final Map<int, List<String>> rejected = <int, List<String>>{};
    for (int index = 0; index < documents.length; index++) {
      final Object? contents = documents[index].contents.value;
      if (contents == null) {
        continue;
      }
      final List<String> missing = <String>[];
      if (contents is! YamlMap) {
        missing.add('is not a mapping, so it names no resource');
      } else {
        if (contents['apiVersion'] is! String) {
          missing.add('has no apiVersion');
        }
        if (contents['kind'] is! String) {
          missing.add('has no kind');
        }
        final Object? metadata = contents['metadata'];
        if (metadata is! YamlMap || metadata['name'] is! String) {
          missing.add('has no metadata.name');
        }
      }
      if (missing.isNotEmpty) {
        rejected[index + 1] = missing;
      }
    }
    return rejected;
  }
}
